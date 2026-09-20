//
//  BallModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 12/01/2026.
//

import Foundation

/// One sighting of the ball, in Vision normalized image space (origin bottom-left, y up).
struct BallObservation: Codable, Equatable {
    let frameID: Int
    /// Centre of the ball — not a bounding-box corner.
    let center: CGPoint
    let radius: CGFloat
    let confidence: CGFloat

    /// Presentation time of this frame, in seconds from the start of the media.
    ///
    /// A second, separate time base from `frameID`, and deliberately so. `frameID` counts
    /// processed frames in uniform steps, which is what the trajectory fit needs — a
    /// parabola in irregular time isn't a parabola. But uniform steps can't be used to
    /// seek: phone footage is frequently variable frame rate, so frame index ÷ nominal
    /// fps drifts further the longer the clip runs. Seeking needs the real timestamp,
    /// so both are carried and never conflated.
    let timeSeconds: Double?

    init(
        frameID: Int,
        center: CGPoint,
        radius: CGFloat,
        confidence: CGFloat,
        timeSeconds: Double? = nil
    ) {
        self.frameID = frameID
        self.center = center
        self.radius = radius
        self.confidence = confidence
        self.timeSeconds = timeSeconds
    }

    /// Build from a detector bounding box (Vision space, origin bottom-left).
    init(frameID: Int, boundingBox: CGRect, confidence: CGFloat, timeSeconds: Double? = nil) {
        self.init(
            frameID: frameID,
            center: CGPoint(x: boundingBox.midX, y: boundingBox.midY),
            // Detector boxes are rarely perfectly square; average the two half-extents.
            radius: (boundingBox.width + boundingBox.height) / 4,
            confidence: confidence,
            timeSeconds: timeSeconds
        )
    }
}

enum BallState: String {
    case idle
    /// Airborne on a ballistic arc that could reach the rim.
    case inFlight
    /// At or below the rim plane, outcome not yet settled.
    case atRim
}

/// From the history of ball detections, the median radius — so a single blown-up or
/// collapsed detection box can't skew the ball size used in clearance tests.
func smoothedRadius(history: [BallObservation], window: Int = 9) -> Double {
    guard !history.isEmpty else { return 0 }
    return median(history.suffix(window).map { Double($0.radius) }) ?? 0
}

/// Mean absolute deviation of the most recent observations from the fitted arc.
///
/// A spike here means the ball stopped following its parabola: it hit the rim, the
/// backboard, or a hand. During a shot that is the signal to keep the attempt open
/// rather than call it, because a rim bounce can still drop in.
func trajectoryResidual(history: [BallObservation], fit: MotionFit, window: Int = 5) -> Double {
    let snippet = history.suffix(window)
    guard !snippet.isEmpty else { return 0 }

    let total = snippet.reduce(0.0) { partial, observation in
        let predicted = predictPosition(fit: fit, t: Double(observation.frameID))
        return partial + hypot(predicted.x - observation.center.x, predicted.y - observation.center.y)
    }

    return total / Double(snippet.count)
}

/// True when the arc broke away from the fit by more than `threshold` ball radii.
///
/// Expressed in ball radii rather than raw normalized units so the same threshold
/// works whether the camera is courtside or up in the stands.
func detectFitBreak(
    history: [BallObservation],
    fit: MotionFit,
    thresholdInRadii: Double = 1.2
) -> Bool {
    guard history.count >= 5 else { return false }

    let radius = smoothedRadius(history: history)
    guard radius > 0 else { return false }

    return trajectoryResidual(history: history, fit: fit) > (thresholdInRadii * radius)
}
