//
//  ShotTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation

/// Everything the UI needs to draw a frame, captured as a value.
///
/// The detector runs on whichever thread is pulling frames; SwiftUI reads on the main
/// actor. Handing across an immutable snapshot rather than sharing the live detector
/// keeps the two apart — the previous design mutated `@Observable` state directly from
/// the Vision completion handler while the view read it.
struct GameSnapshot {
    var sequence: Int = 0
    var frameID: Int = 0

    var ballHistory: [BallObservation] = []
    var rim: HoopGeometry?
    var ballState: BallState = .idle

    /// Fitted arc in normalized image space, for the overlay.
    var arcPoints: [CGPoint] = []

    var predictedCrossingFrame: Double?
    var currentAttempt: ShotAttempt?
}

/// Owns shot detection for one video or camera session.
///
/// Call `ingest*` from the frame-processing thread. Results are handed back through
/// `onSnapshot` / `onEvent`, which the caller is responsible for routing to the UI.
final class ShotTracker {

    private var detector: ShotDetector
    private var rimTracker = RimTracker()

    private var sequence = 0

    /// The frame currently being assembled, and the best ball candidate seen for it.
    ///
    /// A frame can produce a ball sighting from the detector *and* from the object
    /// tracker. Buffering until the frame closes lets the better of the two win, and
    /// guarantees the detector sees exactly one sample per frame — feeding it twice
    /// double-weights that frame in the trajectory fit.
    private var currentFrameID: Int = 0
    private var pendingBall: BallObservation?

    var onSnapshot: ((GameSnapshot) -> Void)?
    var onEvent: ((ShotEvent) -> Void)?

    init(config: ShotDetectorConfig = ShotDetectorConfig()) {
        self.detector = ShotDetector(config: config)
    }

    var rim: HoopGeometry? { rimTracker.geometry }
    var isRimLocked: Bool { rimTracker.isLocked }

    func reset() {
        detector.reset()
        rimTracker.reset()
        pendingBall = nil
        currentFrameID = 0
    }

    /// Open a new frame. Commits whatever the previous frame gathered.
    ///
    /// The driver must call this exactly once per video frame, before running any
    /// detection or tracking for it.
    func beginFrame(_ frameID: Int) {
        commitPendingBall()
        currentFrameID = frameID
        pendingBall = nil
    }

    /// Feed a rim detection. Cheap to call on every detection — the tracker smooths.
    func ingestRim(boundingBox: CGRect, frameID: Int) {
        rimTracker.observe(boundingBox: boundingBox, frameID: frameID)
    }

    /// Offer a ball sighting for the frame currently open. The highest-confidence
    /// candidate for a frame is the one the detector sees.
    func ingestBall(boundingBox: CGRect, confidence: CGFloat, frameID: Int) {
        let observation = BallObservation(
            frameID: frameID,
            boundingBox: boundingBox,
            confidence: confidence
        )

        if let existing = pendingBall, existing.confidence >= observation.confidence {
            return
        }

        pendingBall = observation
    }

    /// Call when the stream ends, so the last frame is committed and an open attempt is
    /// closed out rather than left hanging.
    func endOfStream(atFrame frame: Int) {
        commitPendingBall()

        for event in detector.flush(atFrame: frame) {
            onEvent?(event)
        }
        publishSnapshot(frameID: frame)
    }

    private func commitPendingBall() {
        guard let observation = pendingBall else { return }
        pendingBall = nil

        let events = detector.process(observation: observation, rim: rimTracker.geometry)

        for event in events {
            onEvent?(event)
        }

        publishSnapshot(frameID: observation.frameID)
    }

    private func publishSnapshot(frameID: Int) {
        sequence += 1

        let snapshot = GameSnapshot(
            sequence: sequence,
            frameID: frameID,
            ballHistory: detector.history,
            rim: rimTracker.geometry,
            ballState: detector.state,
            arcPoints: detector.currentAttempt != nil
                ? detector.projectedArc(fromFrame: frameID)
                : [],
            predictedCrossingFrame: detector.predictedCrossingFrame,
            currentAttempt: detector.currentAttempt
        )

        onSnapshot?(snapshot)
    }
}
