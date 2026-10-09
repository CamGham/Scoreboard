//
//  BoxKalmanFilter.swift
//  Scoreboard
//
//  Created by Cam Graham on 09/10/2026.
//

import Foundation

/// Estimates where a player's box is, and where it is heading, from detections that
/// only arrive every few frames.
///
/// The centre moves at a constant velocity; the width and height drift slowly. Each is
/// filtered on its own. That is exact rather than an approximation here: the motion on
/// one axis says nothing about another, and the noise on each is independent, so a
/// single filter over the whole box would keep every cross-axis term at zero anyway.
///
/// Time is counted in frames, like the shot detector, so a prediction across three
/// frames is `predict(frames: 3)`.
///
/// Noise scales with the box's own size on each axis. A distant player has a small box
/// and moves less across the frame than a near one; a fixed amount of noise would make
/// the filter far too loose for one or far too stiff for the other. The weights follow
/// DeepSORT's.
struct BoxKalmanFilter: Equatable {

    /// Measurement noise, as a fraction of the box's size on that axis.
    static let measurementWeight = 1.0 / 20

    /// How far the centre may wander from constant velocity per frame, as a fraction of
    /// the box's size.
    static let positionNoiseWeight = 1.0 / 20

    /// How far the velocity may change per frame, as a fraction of the box's size.
    static let velocityNoiseWeight = 1.0 / 160

    /// How far the width and height may drift per frame, as a fraction of themselves.
    static let sizeNoiseWeight = 1.0 / 40

    private var x: AxisFilter
    private var y: AxisFilter
    private var width: LevelFilter
    private var height: LevelFilter

    /// Start from a single detection. Velocity is unknown, so it starts at zero with
    /// wide uncertainty, and the first few updates settle it.
    init(box: CGRect) {
        let w = Double(box.width)
        let h = Double(box.height)

        x = AxisFilter(
            position: Double(box.midX),
            positionVariance: pow(2 * Self.measurementWeight * w, 2),
            velocityVariance: pow(10 * Self.velocityNoiseWeight * w, 2)
        )
        y = AxisFilter(
            position: Double(box.midY),
            positionVariance: pow(2 * Self.measurementWeight * h, 2),
            velocityVariance: pow(10 * Self.velocityNoiseWeight * h, 2)
        )
        width = LevelFilter(value: w, variance: pow(2 * Self.measurementWeight * w, 2))
        height = LevelFilter(value: h, variance: pow(2 * Self.measurementWeight * h, 2))
    }

    /// The current estimate, in the same space as the detections.
    var box: CGRect {
        CGRect(
            x: x.position - width.value / 2,
            y: y.position - height.value / 2,
            width: width.value,
            height: height.value
        )
    }

    /// Centre velocity per frame.
    var velocity: CGVector {
        CGVector(dx: x.velocity, dy: y.velocity)
    }

    /// Move the estimate forward without a measurement.
    mutating func predict(frames: Int) {
        guard frames > 0 else { return }
        let dt = Double(frames)
        let w = width.value
        let h = height.value

        x.predict(
            dt: dt,
            positionNoise: pow(Self.positionNoiseWeight * w, 2),
            velocityNoise: pow(Self.velocityNoiseWeight * w, 2)
        )
        y.predict(
            dt: dt,
            positionNoise: pow(Self.positionNoiseWeight * h, 2),
            velocityNoise: pow(Self.velocityNoiseWeight * h, 2)
        )
        width.predict(dt: dt, noise: pow(Self.sizeNoiseWeight * w, 2))
        height.predict(dt: dt, noise: pow(Self.sizeNoiseWeight * h, 2))
    }

    /// Fold in a detection of this box.
    mutating func update(with box: CGRect) {
        let w = Double(box.width)
        let h = Double(box.height)

        x.update(measurement: Double(box.midX), noise: pow(Self.measurementWeight * w, 2))
        y.update(measurement: Double(box.midY), noise: pow(Self.measurementWeight * h, 2))
        width.update(measurement: w, noise: pow(Self.measurementWeight * w, 2))
        height.update(measurement: h, noise: pow(Self.measurementWeight * h, 2))
    }
}

// MARK: - One axis

/// Position and velocity along one axis.
private struct AxisFilter: Equatable {
    private(set) var position: Double
    private(set) var velocity: Double = 0

    // Covariance, symmetric: [[pp, pv], [pv, vv]].
    private var pp: Double
    private var pv: Double = 0
    private var vv: Double

    init(position: Double, positionVariance: Double, velocityVariance: Double) {
        self.position = position
        self.pp = positionVariance
        self.vv = velocityVariance
    }

    /// x ← F x, P ← F P Fᵀ + Q, with F = [[1, dt], [0, 1]].
    mutating func predict(dt: Double, positionNoise: Double, velocityNoise: Double) {
        position += velocity * dt

        let newPP = pp + 2 * dt * pv + dt * dt * vv
        let newPV = pv + dt * vv

        // Noise accrues per frame, so a longer gap is less certain.
        pp = newPP + positionNoise * dt
        pv = newPV
        vv += velocityNoise * dt
    }

    /// Standard update with H = [1, 0]: only the position is measured.
    mutating func update(measurement: Double, noise: Double) {
        let innovationVariance = pp + noise
        guard innovationVariance > 0 else { return }

        let gainPosition = pp / innovationVariance
        let gainVelocity = pv / innovationVariance
        let innovation = measurement - position

        position += gainPosition * innovation
        velocity += gainVelocity * innovation

        // P ← (I − K H) P, written out for the 2×2 case.
        let newPP = (1 - gainPosition) * pp
        let newPV = (1 - gainPosition) * pv
        let newVV = vv - gainVelocity * pv

        pp = newPP
        pv = newPV
        vv = newVV
    }
}

/// A value that drifts with no trend of its own — a box's width or height.
private struct LevelFilter: Equatable {
    private(set) var value: Double
    private var variance: Double

    init(value: Double, variance: Double) {
        self.value = value
        self.variance = variance
    }

    mutating func predict(dt: Double, noise: Double) {
        variance += noise * dt
    }

    mutating func update(measurement: Double, noise: Double) {
        let total = variance + noise
        guard total > 0 else { return }

        let gain = variance / total
        value += gain * (measurement - value)
        variance *= (1 - gain)
    }
}
