//
//  PlayerTrackerTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 09/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A player-sized box centred on a point, in Vision space.
private func box(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 0.08, height: CGFloat = 0.25) -> CGRect {
    CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
}

private func player(_ x: CGFloat, _ y: CGFloat, confidence: Float = 0.9) -> PlayerDetection {
    PlayerDetection(boundingBox: box(x, y), confidence: confidence)
}

/// Run frames `range`, with detections from `detections` on every third frame and
/// nothing in between — the cadence the pipeline uses.
private func run(
    _ tracker: inout PlayerTracker,
    frames range: ClosedRange<Int>,
    detections: (Int) -> [PlayerDetection]
) {
    for frame in range {
        tracker.update(frameID: frame, detections: tracker.isDetectionDue(frameID: frame) ? detections(frame) : nil)
    }
}

// MARK: - Filter

@Test("A box that isn't moving stays put")
func stillBoxStaysPut() {
    var filter = BoxKalmanFilter(box: box(0.5, 0.5))
    for _ in 0..<10 {
        filter.predict(frames: 3)
        filter.update(with: box(0.5, 0.5))
    }
    filter.predict(frames: 3)

    #expect(abs(filter.box.midX - 0.5) < 0.002)
    #expect(abs(filter.box.midY - 0.5) < 0.002)
    #expect(abs(filter.velocity.dx) < 0.001)
}

@Test("A box moving steadily is predicted ahead of its last sighting")
func movingBoxIsPredictedAhead() {
    var filter = BoxKalmanFilter(box: box(0.2, 0.4))
    var x: CGFloat = 0.2
    for _ in 0..<10 {
        x += 0.03
        filter.predict(frames: 3)
        filter.update(with: box(x, 0.4))
    }

    #expect(abs(filter.velocity.dx - 0.01) < 0.002)

    filter.predict(frames: 3)
    #expect(abs(filter.box.midX - (x + 0.03)) < 0.006)
}

@Test("The box size follows the detections")
func sizeFollowsDetections() {
    var filter = BoxKalmanFilter(box: box(0.5, 0.5, width: 0.08, height: 0.25))
    for _ in 0..<15 {
        filter.predict(frames: 3)
        filter.update(with: box(0.5, 0.5, width: 0.1, height: 0.3))
    }

    #expect(abs(filter.box.width - 0.1) < 0.005)
    #expect(abs(filter.box.height - 0.3) < 0.01)
}

// MARK: - Showing a player

@Test("A player is shown only once seen on two passes")
func playerNeedsTwoPasses() {
    var tracker = PlayerTracker()

    tracker.update(frameID: 3, detections: [player(0.5, 0.4)])
    #expect(tracker.tracks.count == 1)
    #expect(tracker.visibleTracks.isEmpty)

    tracker.update(frameID: 4, detections: nil)
    tracker.update(frameID: 5, detections: nil)
    tracker.update(frameID: 6, detections: [player(0.5, 0.4)])

    #expect(tracker.visibleTracks.count == 1)
    #expect(tracker.visibleTracks.first?.state == .confirmed)
    #expect(tracker.tracksConfirmed == 1)
}

@Test("A one-off detection never appears")
func oneOffNeverAppears() {
    var tracker = PlayerTracker()
    tracker.update(frameID: 3, detections: [player(0.5, 0.4)])
    tracker.update(frameID: 6, detections: [])

    #expect(tracker.tracks.isEmpty)
    #expect(tracker.tracksConfirmed == 0)
}

@Test("A sweep's detections between passes count as a pass")
func sweepBetweenPassesCounts() {
    var tracker = PlayerTracker()
    tracker.update(frameID: 3, detections: [player(0.5, 0.4)])

    // Frame 4 isn't a scheduled pass, but the ball detector swept the full frame.
    tracker.update(frameID: 4, detections: [player(0.5, 0.4)])

    #expect(tracker.visibleTracks.count == 1)
}

// MARK: - Keeping a player

@Test("A player keeps their ID through a missed pass")
func idSurvivesMissedPass() throws {
    var tracker = PlayerTracker()
    run(&tracker, frames: 1...6) { _ in [player(0.5, 0.4)] }
    let id = try #require(tracker.visibleTracks.first?.id)

    tracker.update(frameID: 9, detections: [])
    #expect(tracker.visibleTracks.first?.id == id)
    #expect(tracker.visibleTracks.first?.state == .coasting)

    tracker.update(frameID: 12, detections: [player(0.5, 0.4)])
    #expect(tracker.visibleTracks.map(\.id) == [id])
    #expect(tracker.visibleTracks.first?.state == .confirmed)
    #expect(tracker.tracksConfirmed == 1)
}

@Test("Boxes keep moving between passes")
func boxesMoveBetweenPasses() throws {
    var tracker = PlayerTracker()

    // Moving right at 0.01 per frame, seen every third frame.
    run(&tracker, frames: 1...30) { frame in [player(0.2 + 0.01 * CGFloat(frame), 0.4)] }
    let atPass = try #require(tracker.visibleTracks.first).box.midX

    tracker.update(frameID: 31, detections: nil)
    tracker.update(frameID: 32, detections: nil)
    let between = try #require(tracker.visibleTracks.first).box.midX

    #expect(between > atPass + 0.015)
}

@Test("Two players crossing keep their own IDs")
func crossingPlayersKeepIDs() throws {
    var tracker = PlayerTracker()

    // One runs right, one runs left, a little apart vertically. They pass each other
    // around frame 20. At the first pass after crossing, each detection overlaps the
    // *other* player's last box more than its own — only the motion keeps them apart.
    func positions(at frame: Int) -> (right: CGFloat, left: CGFloat) {
        (0.2 + 0.01 * CGFloat(frame), 0.6 - 0.01 * CGFloat(frame))
    }

    run(&tracker, frames: 1...12) { frame in
        let p = positions(at: frame)
        return [player(p.right, 0.30), player(p.left, 0.33)]
    }

    let beforeCrossing = tracker.visibleTracks
    let runningRight = try #require(beforeCrossing.min { $0.box.midX < $1.box.midX }).id
    let runningLeft = try #require(beforeCrossing.max { $0.box.midX < $1.box.midX }).id

    run(&tracker, frames: 13...36) { frame in
        let p = positions(at: frame)
        return [player(p.right, 0.30), player(p.left, 0.33)]
    }

    let after = tracker.visibleTracks
    #expect(after.count == 2)
    #expect(after.first { $0.id == runningRight }?.velocity.dx ?? 0 > 0)
    #expect(after.first { $0.id == runningLeft }?.velocity.dx ?? 0 < 0)
    #expect(tracker.tracksConfirmed == 2)
}

@Test("A weak detection keeps a player but never starts one")
func weakDetectionsOnlyExtend() throws {
    var tracker = PlayerTracker()
    run(&tracker, frames: 1...6) { _ in [player(0.3, 0.4)] }
    let id = try #require(tracker.visibleTracks.first?.id)

    // Partly hidden, so scored lower — and a weak box somewhere nobody was.
    tracker.update(frameID: 9, detections: [player(0.3, 0.4, confidence: 0.4), player(0.8, 0.4, confidence: 0.4)])

    #expect(tracker.tracks.map(\.id) == [id])
    #expect(tracker.visibleTracks.first?.state == .confirmed)
}

@Test("A detection nowhere near a player starts someone new")
func distantDetectionIsSomeoneElse() throws {
    var tracker = PlayerTracker()
    run(&tracker, frames: 1...6) { _ in [player(0.2, 0.4)] }
    let id = try #require(tracker.visibleTracks.first?.id)

    tracker.update(frameID: 9, detections: [player(0.7, 0.4)])

    #expect(tracker.tracks.first { $0.id == id }?.state == .coasting)
    #expect(tracker.tracks.contains { $0.id != id && $0.state == .tentative })
}

// MARK: - Losing a player

@Test("A player gone too long is dropped, and comes back as someone new")
func longGoneIsDropped() throws {
    var tracker = PlayerTracker()
    run(&tracker, frames: 1...6) { _ in [player(0.5, 0.4)] }
    let id = try #require(tracker.visibleTracks.first?.id)

    run(&tracker, frames: 7...(6 + PlayerTracker.Config().maxCoastFrames + 3)) { _ in [] }
    #expect(tracker.tracks.isEmpty)
    #expect(tracker.endedTracks == 1)

    let back = 6 + PlayerTracker.Config().maxCoastFrames + 3
    run(&tracker, frames: (back + 1)...(back + 6)) { _ in [player(0.5, 0.4)] }
    #expect(tracker.visibleTracks.count == 1)
    #expect(tracker.visibleTracks.first?.id != id)
    #expect(tracker.tracksConfirmed == 2)
}

@Test("Many players are all followed, with no cap")
func noTrackCap() {
    var tracker = PlayerTracker()
    let court = (0..<10).map { CGFloat($0) * 0.1 + 0.05 }

    run(&tracker, frames: 1...6) { _ in court.map { player($0, 0.4) } }

    #expect(tracker.visibleTracks.count == 10)
}
