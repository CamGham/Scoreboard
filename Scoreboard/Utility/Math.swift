//
//  Math.swift
//  Scoreboard
//
//  Created by Cam Graham on 13/01/2026.
//

import Foundation
import Accelerate

func clamp01(value: Double) -> Double {
    return max(0.0, min(1.0, value))
}

// x = a*t + b
typealias LinearFit = (Double, Double)

// y = a*t² + b*t + c
typealias QuadraticFit = (Double, Double, Double)

struct MotionFit {
    let px: LinearFit
    let py: QuadraticFit
}


// TODO: given a history snippet, t needs to be relative from 0, not using FrameID?

// given frame 't' (essentially representing time in the quation) find the x and y value
func predictPosition(fit: MotionFit, t: Int) -> (x: Double, y: Double) {
    // Convert `t` to Double once to avoid mixed-type arithmetic and help the type checker
    let td = Double(t)

    // Unpack coefficients for readability and performance of type checking
    let (ax, bx) = fit.px
    let (ay, by, cy) = fit.py

    // Compute x and y using smaller sub-expressions
    let x = (ax * td) + bx
    let yQuad = ay * td * td
    let yLin = by * td
    let y = yQuad + yLin + cy

    return (x: x, y: y)
    
//    return (
//        x: ((fit.px.0 * t) + (fit.px.1)),
//        y: (fit.py.0 * t * t) + (fit.py.1 * t) + (fit.py.2)
//    )
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
    return Atb_copy
}


func fitMotionWeighted(
    _ points: [BallObservation],
    decay: Double = 0.92
) -> MotionFit? {

    guard points.count >= 5 else { return nil }

    let t = points.map { Double($0.frameID) }
    let x = points.map { Double($0.center.x) }
    let y = points.map { Double($0.center.y) }

    let tMax = t.max()!
    let w = t.map { pow(decay, tMax - $0) }

    let n = points.count

    // -------------------------
    // X fit: linear (a*t + b)
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
    // Y fit: quadratic (a*t² + b*t + c)
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

    return MotionFit(
        px: (px[0], px[1]),
        py: (py[0], py[1], py[2])
    )
}

func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
    guard count > 1 else { return [start] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { start + Double($0) * step }
}
