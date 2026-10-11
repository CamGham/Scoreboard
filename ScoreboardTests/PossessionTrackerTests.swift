//
//  PossessionTrackerTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 11/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A player-sized track centred on a point, in Vision space.
private func track(_ id: Int, x: CGFloat, y: CGFloat = 0.4) -> PlayerTrack {
    let width: CGFloat = 0.08
    let height: CGFloat = 0.25
    return PlayerTrack(
        id: id,
        box: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height),
        velocity: .zero,
        state: .confirmed,
        confidence: 0.9,
        firstFrame: 0,
        lastSeenFrame: 0,
        hits: 2
    )
}

// Player 1's box spans x 0.26–0.34, y 0.275–0.525; their reach x 0.24–0.36, y 0.25–0.60.
// Player 2 stands well clear at x 0.6.
private let one = track(1, x: 0.3)
private let two = track(2, x: 0.6)

private let withOne = CGPoint(x: 0.30, y: 0.45)
private let withTwo = CGPoint(x: 0.60, y: 0.45)
private let nowhere = CGPoint(x: 0.45, y: 0.85)

private func feed(
    _ tracker: inout PossessionTracker,
    frames: ClosedRange<Int>,
    ball: CGPoint?,
    players: [PlayerTrack] = [one, two]
) {
    for frame in frames {
        tracker.update(frameID: frame, timeSeconds: Double(frame) / 30, ball: ball, players: players)
    }
}

/// Player 1 holding the ball from frame 1 to 3.
private func oneHolding() -> PossessionTracker {
    var tracker = PossessionTracker()
    feed(&tracker, frames: 1...3, ball: withOne)
    return tracker
}

// MARK: - Who holds it

@Test("The first holder takes the ball after three sightings, from the first of them")
func firstHolderNeedsThreeSightings() {
    var tracker = PossessionTracker()
    feed(&tracker, frames: 1...2, ball: withOne)
    #expect(tracker.holderID == nil)

    feed(&tracker, frames: 3...3, ball: withOne)
    #expect(tracker.holderID == 1)
    #expect(tracker.record.frames.map(\.frameID) == [1, 2, 3])
}

@Test("A ball raised above the head is still held")
func overheadIsHeld() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...5, ball: CGPoint(x: 0.30, y: 0.57))
    #expect(tracker.holderID == 1)
}

@Test("A ball dribbled just below the box is still held")
func dribbleIsHeld() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...5, ball: CGPoint(x: 0.30, y: 0.26))
    #expect(tracker.holderID == 1)
}

@Test("A ball outside everyone's reach is loose and credited to the last holder")
func looseBall() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...6, ball: nowhere)

    #expect(tracker.holderID == nil)
    #expect(tracker.lastHolderID == 1)
    #expect(tracker.record.frames.last?.frameID == 3)
}

// MARK: - Changing hands

@Test("A pass changes hands after three sightings, and the catch is dated from the first")
func passNeedsThreeSightings() {
    var tracker = oneHolding()

    feed(&tracker, frames: 4...5, ball: withTwo)
    #expect(tracker.holderID == 1)

    feed(&tracker, frames: 6...6, ball: withTwo)
    #expect(tracker.holderID == 2)
    #expect(tracker.lastHolderID == 1)

    // Frames 4 and 5 were provisionally player 1's; the confirmed switch gives them back.
    #expect(tracker.record.frames.map(\.playerID) == [1, 1, 1, 2, 2, 2])
    #expect(tracker.record.touches.map(\.playerID) == [1, 2])
}

@Test("A ball brushing past someone for one frame stays where it was")
func briefBrushDoesNotMove() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...4, ball: withTwo)
    feed(&tracker, frames: 5...6, ball: withOne)

    #expect(tracker.holderID == 1)
    #expect(tracker.record.frames.allSatisfy { $0.playerID == 1 })
    #expect(tracker.record.frames.count == 6)
}

@Test("Between two players, the holder keeps a tie and the nearer box wins otherwise")
func contestedBall() {
    // Overlapping: player 1 spans x 0.26–0.34, player 3 spans 0.32–0.40.
    let three = track(3, x: 0.36)
    var tracker = PossessionTracker()
    feed(&tracker, frames: 1...3, ball: CGPoint(x: 0.28, y: 0.45), players: [one, three])
    #expect(tracker.holderID == 1)

    // Inside both boxes: a tie, so the holder keeps it.
    feed(&tracker, frames: 4...8, ball: CGPoint(x: 0.33, y: 0.45), players: [one, three])
    #expect(tracker.holderID == 1)

    // Inside player 3's box, only within player 1's reach: 3 is nearer.
    feed(&tracker, frames: 9...11, ball: CGPoint(x: 0.35, y: 0.45), players: [one, three])
    #expect(tracker.holderID == 3)
}

@Test("The last holder taking back a loose ball isn't a new touch")
func lastHolderRegains() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...5, ball: nowhere)
    feed(&tracker, frames: 6...6, ball: withOne)

    #expect(tracker.holderID == 1)
    #expect(tracker.record.touches.count == 1)
}

// MARK: - Unseen and lapsing

@Test("An unseen ball stays with the holder, flagged as unseen")
func unseenStaysWithHolder() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...10, ball: nil)

    #expect(tracker.holderID == 1)
    #expect(tracker.record.frames.count == 10)
    #expect(tracker.record.frames.suffix(7).allSatisfy { !$0.ballSeen })
    #expect(tracker.record.frames.prefix(3).allSatisfy { $0.ballSeen })
}

@Test("Possession ends after the ball has been unseen for two seconds")
func lapsesWhenUnseenTooLong() {
    var tracker = oneHolding()
    let limit = PossessionTracker.Config().maxUnseenFrames
    feed(&tracker, frames: 4...(3 + limit + 1), ball: nil)

    #expect(tracker.holderID == nil)
    #expect(tracker.lastHolderID == nil)
    #expect(tracker.record.frames.last?.frameID == 3 + limit)
}

@Test("Possession ends when the holder's track is dropped")
func lapsesWhenHolderGone() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...4, ball: nil, players: [two])

    #expect(tracker.holderID == nil)
    #expect(tracker.record.frames.last?.frameID == 3)
}

// MARK: - The record

@Test("Touches are runs of the same holder, with where and when they began and ended")
func touchesFromRuns() throws {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...5, ball: nowhere)
    feed(&tracker, frames: 6...7, ball: withOne)
    feed(&tracker, frames: 8...10, ball: withTwo)

    let touches = tracker.record.touches
    #expect(touches.map(\.playerID) == [1, 2])

    let first = try #require(touches.first)
    #expect(first.startFrame == 1)
    #expect(first.endFrame == 7)
    #expect(first.firstBox == one.box)
    #expect(first.endTime == 7.0 / 30)
    #expect(touches.last?.startFrame == 8)
}

@Test("A frame's holder can be looked up")
func lookUpFrame() {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...5, ball: nowhere)
    feed(&tracker, frames: 6...8, ball: withTwo)

    #expect(tracker.record.frame(at: 2)?.playerID == 1)
    #expect(tracker.record.frame(at: 5) == nil)
    #expect(tracker.record.frame(at: 7)?.playerID == 2)
}

@Test("Possession survives a save and load with the run")
func possessionRoundTrip() throws {
    var tracker = oneHolding()
    feed(&tracker, frames: 4...6, ball: withTwo)

    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: [],
        possession: tracker.record
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.possession == tracker.record)
}

@Test("A run saved before possession existed still loads")
func runWithoutPossessionLoads() throws {
    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: []
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.possession == nil)
}
