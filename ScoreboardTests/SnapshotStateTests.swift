//
//  SnapshotStateTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 05/11/2026.
//

import Testing
import Foundation
@testable import Scoreboard

// MARK: - Fixtures

private let snapshotRim = HoopGeometry(
    center: CGPoint(x: 0.5, y: 0.70),
    verticalRadius: 0.012,
    horizontalRadius: 0.045
)

private let snapshotBallRadius: CGFloat = 0.022

/// Through the same encoder and decoder a saved snapshot goes through.
private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try SnapshotCoding.encoder().encode(value)
    return try SnapshotCoding.decoder().decode(T.self, from: data)
}

/// Ball centres for a shot that drops through the middle of `snapshotRim`, one per frame.
private func madeShot(frames: Int = 30) -> [CGPoint] {
    let fromX = 0.15, fromY = 0.35, peakY = 0.88
    let planeY = Double(snapshotRim.center.y)

    // Choose the landing x so the descending arc crosses the rim plane at its centre.
    let ratio = (planeY - fromY) / (peakY - fromY)
    let sCross = (1 + (1 - ratio).squareRoot()) / 2
    let landX = fromX + (Double(snapshotRim.center.x) - fromX) / sCross

    return (0...frames).map { step in
        let s = Double(step) / Double(frames)
        return CGPoint(x: fromX + (landX - fromX) * s, y: fromY + 4 * (peakY - fromY) * s * (1 - s))
    }
}

/// A shot tracker the way the pipeline sets one up, recording what it reports.
private final class RecordedTracker {
    let tracker = ShotTracker()
    var events: [ShotEvent] = []

    init() {
        tracker.setUserRim(snapshotRim)
        tracker.onEvent = { [unowned self] in events.append($0) }
    }

    func feed(_ centres: ArraySlice<CGPoint>, firstFrame: Int) {
        for (offset, centre) in centres.enumerated() {
            let frame = firstFrame + offset
            tracker.beginFrame(frame, timeSeconds: Double(frame) / 30)
            tracker.ingestBall(
                boundingBox: CGRect(
                    x: centre.x - snapshotBallRadius, y: centre.y - snapshotBallRadius,
                    width: snapshotBallRadius * 2, height: snapshotBallRadius * 2
                ),
                confidence: 0.9,
                frameID: frame
            )
        }
    }

    var resolved: [ShotAttempt] {
        events.compactMap {
            if case .attemptResolved(let attempt) = $0 { return attempt }
            return nil
        }
    }
}

// MARK: - Shot side

@Test("A shot tracker restored mid-flight judges the rest of the shot as the original does")
func shotTrackerResumesMidFlight() throws {
    let shot = madeShot()
    let split = 22  // after the apex, with the attempt open and the ball coming down

    let original = RecordedTracker()
    original.feed(shot[..<split], firstFrame: 1)

    let saved = try roundTrip(original.tracker.snapshotState)
    #expect(saved.detector.currentAttempt != nil, "the split should land mid-attempt")
    #expect(saved.pendingBall != nil, "the last frame's ball is still waiting to be committed")

    let restored = RecordedTracker()
    restored.tracker.restore(from: saved)

    original.feed(shot[split...], firstFrame: 1 + split)
    restored.feed(shot[split...], firstFrame: 1 + split)
    original.tracker.endOfStream(atFrame: 40)
    restored.tracker.endOfStream(atFrame: 40)

    #expect(original.resolved.count == 1)
    #expect(restored.resolved == original.resolved)
    #expect(restored.tracker.snapshotState == original.tracker.snapshotState)
}

@Test("A rim survives the trip, detected or placed by hand")
func rimTrackerRoundTrip() throws {
    var detected = RimTracker()
    detected.observe(boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024), frameID: 3)
    detected.observe(boundingBox: CGRect(x: 0.46, y: 0.69, width: 0.09, height: 0.024), frameID: 9)

    var placed = RimTracker()
    placed.setUserPlaced(snapshotRim)

    for rim in [detected, placed] {
        var restored = RimTracker()
        restored.restore(from: try roundTrip(rim.snapshotState))

        #expect(restored.snapshotState == rim.snapshotState)
        #expect(restored.geometry == rim.geometry)
        #expect(restored.isUserPlaced == rim.isUserPlaced)
    }
}

@Test("An arc fit survives the trip, including a non-finite error")
func motionFitRoundTrip() throws {
    let fit = MotionFit(px: (0.01, 0.4), py: (-0.002, 0.03, 0.8), referenceFrame: 1_204, sampleCount: 18, rmse: .nan)

    let decoded = try roundTrip(fit)

    #expect(decoded == fit)
    #expect(decoded.isBallistic)
}

@MainActor
@Test("The shots found so far survive the trip, and the overlay starts counting again")
func gameStateRoundTrip() throws {
    let tracker = RecordedTracker()
    tracker.feed(madeShot()[...], firstFrame: 1)
    tracker.tracker.endOfStream(atFrame: 40)

    let original = GameState()
    for event in tracker.events { original.handle(event) }
    #expect(original.shotTimeline.count == 1)

    let restored = GameState()
    restored.apply(GameSnapshot(sequence: 50))
    restored.restore(from: try roundTrip(original.snapshotState))

    #expect(restored.snapshotState == original.snapshotState)
    #expect(restored.stats == original.stats)

    // The restored shot tracker numbers on from where it left off; nothing it sends
    // may be dropped as older than a picture from before the restore.
    restored.apply(GameSnapshot(sequence: 1))
    #expect(restored.snapshot.sequence == 1)
}

@Test("A ball detector's search state survives the trip")
func ballDetectorRoundTrip() async throws {
    let tracker = VisionTracker()
    let model = try #require(await tracker.awaitVisionModel())

    let original = BallDetector(model: model)
    original.restore(from: BallDetector.State(
        consecutiveMisses: 4,
        stats: BallDetectionStats(framesProcessed: 120, croppedAttempts: 80, croppedHits: 71),
        lastMode: .cropped(CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.2))
    ))

    let restored = BallDetector(model: model)
    restored.restore(from: try roundTrip(original.snapshotState))

    #expect(restored.snapshotState == original.snapshotState)
}
