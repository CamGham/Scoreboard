//
//  Math.swift
//  Scoreboard
//
//  Created by Cam Graham on 13/01/2026.
//

import Foundation
import Accelerate

// MARK: - Coordinate convention
//
// Everything in the tracking pipeline works in Vision's normalized image space:
//
//      origin (0,0) is BOTTOM-LEFT
//      x increases to the RIGHT
//      y increases UPWARD
//
// So a ball under gravity traces a downward-opening parabola: the quadratic
// coefficient of y(t) is NEGATIVE, "rising" means vy > 0, "falling" means vy < 0.
// Only the SwiftUI overlay layer flips y, because SwiftUI's origin is top-left.

func clamp01(value: Double) -> Double {
    return max(0.0, min(1.0, value))
}

// x = a*τ + b
typealias LinearFit = (Double, Double)

// y = a*τ² + b*τ + c
typealias QuadraticFit = (Double, Double, Double)

/// A ballistic fit of the ball's recent motion.
///
/// The polynomials are expressed in *local* time `τ = t - referenceFrame`, not in
/// absolute frame numbers. Fitting against absolute frame IDs (which climb into the
/// thousands) makes the normal equations badly conditioned — `τ²` reaches 10⁶+ and the
/// quadratic coefficient drowns in floating-point cancellation. Keeping τ small and
/// centred on the newest sample keeps the fit stable and makes the coefficients
/// directly comparable between shots.
struct MotionFit {
    let px: LinearFit
    let py: QuadraticFit

    /// Absolute frame that `τ = 0` corresponds to (the newest observation in the window).
    let referenceFrame: Double

    /// Number of observations the fit was built from.
    let sampleCount: Int

    /// Root-mean-square residual of the fit, in normalized image units.
    let rmse: Double

    /// Local time for an absolute frame.
    func localTime(for frame: Double) -> Double {
        frame - referenceFrame
    }

    /// True when the arc opens downward, i.e. the ball is under gravity rather than
    /// being carried, dribbled or mis-tracked.
    var isBallistic: Bool {
        py.0 < 0
    }
}

/// Position on the fitted arc at an absolute frame.
func predictPosition(fit: MotionFit, t: Double) -> (x: Double, y: Double) {
    let tau = fit.localTime(for: t)

    let (ax, bx) = fit.px
    let (ay, by, cy) = fit.py

    let x = (ax * tau) + bx
    let y = (ay * tau * tau) + (by * tau) + cy

    return (x: x, y: y)
}

/// Velocity on the fitted arc at an absolute frame, in normalized units per frame.
/// `vy > 0` is rising, `vy < 0` is falling.
func predictVelocity(fit: MotionFit, t: Double) -> (vx: Double, vy: Double) {
    let tau = fit.localTime(for: t)

    let (ax, _) = fit.px
    let (ay, by, _) = fit.py

    return (vx: ax, vy: (2.0 * ay * tau) + by)
}

/// Absolute frame at which the fitted arc reaches its highest point, and that height.
/// Returns nil when the arc is not ballistic (no maximum).
func predictApex(fit: MotionFit) -> (frame: Double, y: Double)? {
    let (ay, by, cy) = fit.py
    guard ay < 0 else { return nil }

    let tauApex = -by / (2.0 * ay)
    let yApex = (ay * tauApex * tauApex) + (by * tauApex) + cy

    return (frame: fit.referenceFrame + tauApex, y: yApex)
}

/// Absolute frame at which the fitted arc crosses `yTarget` while *descending*.
///
/// Solved analytically rather than by scanning, so the answer carries sub-frame
/// precision — which matters, because the ball moves a large fraction of a rim
/// diameter between consecutive frames.
func findDownwardCrossing(
    fit: MotionFit,
    yTarget: Double,
    after fromFrame: Double,
    before toFrame: Double
) -> Double? {

    let (ay, by, cy) = fit.py
    let c = cy - yTarget

    var roots: [Double] = []

    if abs(ay) < 1e-12 {
        // Degenerate: straight line in y.
        guard abs(by) > 1e-12 else { return nil }
        roots = [-c / by]
    } else {
        let discriminant = (by * by) - (4.0 * ay * c)
        guard discriminant >= 0 else { return nil }

        let sqrtDisc = sqrt(discriminant)
        roots = [
            (-by + sqrtDisc) / (2.0 * ay),
            (-by - sqrtDisc) / (2.0 * ay)
        ]
    }

    let candidates = roots
        .map { fit.referenceFrame + $0 }
        // Descending only: dy/dτ < 0 at the crossing.
        .filter { predictVelocity(fit: fit, t: $0).vy < 0 }
        .filter { $0 >= fromFrame && $0 <= toFrame }
        .sorted()

    return candidates.first
}

func solveWeightedLeastSquares(
    A: [Double],
    rows: Int,
    cols: Int,
    b: [Double],
    w: [Double]
) -> [Double]? {

    precondition(A.count == rows * cols)
    precondition(b.count == rows)
    precondition(w.count == rows)

    // Apply sqrt(weights)
    let sqrtW = w.map { sqrt($0) }

    var Aw = A
    var bw = b

    for i in 0..<rows {
        let wi = sqrtW[i]
        for j in 0..<cols {
            Aw[i * cols + j] *= wi
        }
        bw[i] *= wi
    }

    // Compute AᵀA explicitly to avoid vDSP_mmulD signature mismatches
    var AtA = [Double](repeating: 0, count: cols * cols)
    for i in 0..<cols {            // row in AtA
        for j in 0..<cols {        // col in AtA
            var sum = 0.0
            for k in 0..<rows {    // over rows of Aw
                sum += Aw[k * cols + i] * Aw[k * cols + j]
            }
            AtA[i * cols + j] = sum
        }
    }

    // Compute Aᵀb explicitly
    var Atb = [Double](repeating: 0, count: cols)
    for i in 0..<cols {
        var sum = 0.0
        for k in 0..<rows {
            sum += Aw[k * cols + i] * bw[k]
        }
        Atb[i] = sum
    }

    // Solve (AtA)x = Atb
    var n = __CLPK_integer(cols)
    var nrhs = __CLPK_integer(1)
    var lda = n
    var ldb = n
    var ipiv = [__CLPK_integer](repeating: 0, count: cols)
    var info: __CLPK_integer = 0

    var AtA_copy = AtA
    var Atb_copy = Atb

    dgesv_(
        &n,
        &nrhs,
        &AtA_copy,
        &lda,
        &ipiv,
        &Atb_copy,
        &ldb,
        &info
    )

    guard info == 0 else { return nil }
    guard Atb_copy.allSatisfy({ $0.isFinite }) else { return nil }
    return Atb_copy
}

/// Weighted least-squares ballistic fit: linear in x, quadratic in y.
///
/// Recent samples are weighted more heavily (`decay` per frame of age) so the fit
/// tracks the live arc rather than lagging behind it.
func fitMotionWeighted(
    _ points: [BallObservation],
    decay: Double = 0.8
) -> MotionFit? {

    guard points.count >= 5 else { return nil }

    let absoluteT = points.map { Double($0.frameID) }
    let x = points.map { Double($0.center.x) }
    let y = points.map { Double($0.center.y) }

    // Fit in local time, anchored on the newest sample, so τ ∈ [-(window-1), 0].
    let referenceFrame = absoluteT.max()!
    let t = absoluteT.map { $0 - referenceFrame }

    // A window that spans no time at all (e.g. duplicate frame IDs) has no arc to fit.
    guard let tMin = t.min(), tMin < -1e-9 else { return nil }

    let w = t.map { pow(decay, -$0) }

    let n = points.count

    // -------------------------
    // X fit: linear (a*τ + b)
    // -------------------------

    var Ax = [Double](repeating: 0, count: n * 2)
    for i in 0..<n {
        Ax[i * 2 + 0] = t[i]
        Ax[i * 2 + 1] = 1.0
    }

    guard let px = solveWeightedLeastSquares(
        A: Ax,
        rows: n,
        cols: 2,
        b: x,
        w: w
    ) else { return nil }

    // -------------------------
    // Y fit: quadratic (a*τ² + b*τ + c)
    // -------------------------

    var Ay = [Double](repeating: 0, count: n * 3)
    for i in 0..<n {
        Ay[i * 3 + 0] = t[i] * t[i]
        Ay[i * 3 + 1] = t[i]
        Ay[i * 3 + 2] = 1.0
    }

    guard let py = solveWeightedLeastSquares(
        A: Ay,
        rows: n,
        cols: 3,
        b: y,
        w: w
    ) else { return nil }

    // Unweighted RMSE over the window, so callers can judge fit quality on a
    // scale that means the same thing regardless of the decay used.
    var squaredError = 0.0
    for i in 0..<n {
        let xHat = (px[0] * t[i]) + px[1]
        let yHat = (py[0] * t[i] * t[i]) + (py[1] * t[i]) + py[2]
        squaredError += ((xHat - x[i]) * (xHat - x[i])) + ((yHat - y[i]) * (yHat - y[i]))
    }
    let rmse = sqrt(squaredError / Double(n))

    return MotionFit(
        px: (px[0], px[1]),
        py: (py[0], py[1], py[2]),
        referenceFrame: referenceFrame,
        sampleCount: n,
        rmse: rmse
    )
}

func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
    guard count > 1 else { return [start] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { start + Double($0) * step }
}

/// Median of a set of values. Returns nil for an empty input.
func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0
        ? (sorted[mid - 1] + sorted[mid]) * 0.5
        : sorted[mid]
}
