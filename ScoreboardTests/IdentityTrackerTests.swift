//
//  IdentityTrackerTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 11/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A player-sized box centred on a point, in Vision space.
private func box(_ x: CGFloat, _ y: CGFloat = 0.5) -> CGRect {
    CGRect(x: x - 0.04, y: y - 0.125, width: 0.08, height: 0.25)
}

/// A visible track at `x`, matched on `seen` unless it is coasting.
private func track(
    _ id: Int,
    at x: CGFloat,
    first: Int = 0,
    seen: Int,
    state: PlayerTrack.State = .confirmed
) -> PlayerTrack {
    PlayerTrack(
        id: id,
        box: box(x),
        velocity: .zero,
        state: state,
        confidence: 0.9,
        firstFrame: first,
        lastSeenFrame: seen,
        hits: 2
    )
}

/// Feed the same tracks on every frame in `range`, each matched on that frame.
private func feed(
    _ tracker: inout IdentityTracker,
    frames range: ClosedRange<Int>,
    tracks: (Int) -> [PlayerTrack]
) {
    for frame in range {
        tracker.update(frameID: frame, tracks: tracks(frame))
    }
}

/// A 1v1 with track 1 at x 0.3 and track 2 at x 0.7, both seen up to frame 10.
private func oneOnOne() -> IdentityTracker {
    var tracker = IdentityTracker(format: .oneOnOne)
    feed(&tracker, frames: 1...10) { frame in
        [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)]
    }
    return tracker
}

// MARK: - Numbering

@Test("The first players seen are numbered in the order they appeared")
func playersNumberedInOrder() {
    var tracker = IdentityTracker(format: .oneOnOne)
    let later = track(5, at: 0.7, first: 3, seen: 4)
    let earlier = track(9, at: 0.3, first: 1, seen: 4)

    tracker.update(frameID: 4, tracks: [later, earlier])

    let labels = tracker.labels(for: [later, earlier])
    #expect(labels[9] == "P1")
    #expect(labels[5] == "P2")
    #expect(tracker.summary.playersSeen == 2)
    #expect(tracker.summary.relinks == 0)
}

@Test("A format sets how many players there are")
func formatSetsPlayerCount() {
    #expect(IdentityTracker(format: .shootaround).record.players.count == 1)
    #expect(IdentityTracker(format: .threeOnThree).record.players.map(\.label) == ["P1", "P2", "P3", "P4", "P5", "P6"])
}

// MARK: - Relinking

@Test("When a track ends, a new track near where it was carries on as that player")
func endedTrackRelinks() {
    var tracker = oneOnOne()

    let replacement = track(7, at: 0.32, first: 11, seen: 11)
    tracker.update(frameID: 11, tracks: [track(2, at: 0.7, first: 1, seen: 11), replacement])

    #expect(tracker.labels(for: [replacement])[7] == "P1")
    #expect(tracker.record.player(forTrack: 7, at: 11)?.number == 1)
    #expect(tracker.summary.relinks == 1)
    #expect(tracker.summary.playersSeen == 2)
}

@Test("With two players free, a new track goes to the nearer one")
func nearerPlayerWins() {
    var tracker = oneOnOne()

    let replacement = track(7, at: 0.66, first: 11, seen: 11)
    tracker.update(frameID: 11, tracks: [replacement])

    #expect(tracker.labels(for: [replacement])[7] == "P2")
}

@Test("A track too far from where a player was last seen waits until they could have got there")
func distantTrackWaits() {
    var tracker = oneOnOne()

    // P1 was at 0.3 on frame 10; 0.45 away needs (0.45 - 0.1) / 0.02 = 17.5 frames.
    let stranger = track(7, at: 0.75, first: 11, seen: 11)
    let other = { (frame: Int) in track(2, at: 0.9, first: 1, seen: frame) }

    feed(&tracker, frames: 11...20) { [other($0), stranger] }
    #expect(tracker.labels(for: [stranger])[7] == nil)

    feed(&tracker, frames: 21...30) { [other($0), stranger] }
    #expect(tracker.labels(for: [stranger])[7] == "P1")
}

@Test("A coasting box isn't taken as where the player is")
func coastingBoxIsNotASighting() {
    var tracker = IdentityTracker(format: .shootaround)
    feed(&tracker, frames: 1...10) { [track(1, at: 0.3, first: 1, seen: $0)] }

    // The prediction drifts away while nothing matches it.
    feed(&tracker, frames: 11...12) { _ in [track(1, at: 0.6, first: 1, seen: 10, state: .coasting)] }

    // A new track back where the player was last actually seen: 0.02 from the sighting,
    // but 0.28 from the drifted prediction — further than either allowance would cover.
    let replacement = track(4, at: 0.32, first: 13, seen: 13)
    tracker.update(frameID: 13, tracks: [replacement])

    #expect(tracker.labels(for: [replacement])[4] == "P1")
}

// MARK: - More tracks than players

@Test("With every player taken, an extra track gets nobody until one comes free")
func extraTrackWaitsForAFreePlayer() {
    var tracker = IdentityTracker(format: .shootaround)
    let duplicate = { (frame: Int) in track(2, at: 0.35, first: 3, seen: frame) }

    feed(&tracker, frames: 1...5) { frame in
        [track(1, at: 0.3, first: 1, seen: frame)] + (frame >= 3 ? [duplicate(frame)] : [])
    }
    #expect(tracker.labels(for: [duplicate(5)])[2] == nil)
    #expect(tracker.summary.unassignedTracks == 1)

    tracker.update(frameID: 6, tracks: [duplicate(6)])

    #expect(tracker.labels(for: [duplicate(6)])[2] == "P1")
    #expect(tracker.summary.unassignedTracks == 0)
}

@Test("An extra track that ends without a player is counted")
func endedExtraTrackIsCounted() {
    var tracker = IdentityTracker(format: .shootaround)
    feed(&tracker, frames: 1...5) { [track(1, at: 0.3, first: 1, seen: $0), track(2, at: 0.8, first: 1, seen: $0)] }
    feed(&tracker, frames: 6...7) { [track(1, at: 0.3, first: 1, seen: $0)] }

    #expect(tracker.summary.unassignedTracks == 1)
}

// MARK: - Record

@Test("A track that claims a player late is that player from its first frame")
func lateClaimIsBackdated() {
    var tracker = IdentityTracker(format: .shootaround)
    let duplicate = { (frame: Int) in track(2, at: 0.35, first: 3, seen: frame) }

    feed(&tracker, frames: 1...5) { frame in
        [track(1, at: 0.3, first: 1, seen: frame)] + (frame >= 3 ? [duplicate(frame)] : [])
    }
    tracker.update(frameID: 6, tracks: [duplicate(6)])

    let record = tracker.record
    #expect(record.player(forTrack: 2, at: 3)?.number == 1)
    #expect(record.player(forTrack: 2, at: 2) == nil)
    #expect(record.player(forTrack: 1, at: 4)?.number == 1)
}

@Test("A segment ends on the track's last matched frame, and lookups past it still find the player")
func segmentEndsAtLastMatch() {
    var tracker = IdentityTracker(format: .shootaround)
    feed(&tracker, frames: 1...10) { [track(1, at: 0.3, first: 1, seen: $0)] }
    feed(&tracker, frames: 11...15) { _ in [track(1, at: 0.3, first: 1, seen: 10, state: .coasting)] }

    #expect(tracker.record.segments.map(\.endFrame) == [10])
    #expect(tracker.record.player(forTrack: 1, at: 14)?.number == 1)
}

@Test("Identities survive a save and load with the run")
func identitiesRoundTrip() throws {
    var tracker = oneOnOne()
    tracker.update(frameID: 11, tracks: [track(7, at: 0.32, first: 11, seen: 11)])

    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: [],
        identities: tracker.record
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.identities == tracker.record)
}

@Test("A run saved before identities existed still loads")
func runWithoutIdentitiesLoads() throws {
    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: []
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.identities == nil)
}

@Test("Tracking stats saved before identities still load")
func trackingSummaryWithoutIdentityLoads() throws {
    let json = #"{"config":{"detectionInterval":3,"highConfidence":0.6,"lowConfidence":0.25,"minimumOverlap":0.3,"passesToConfirm":2,"maxCoastFrames":30},"tracksConfirmed":23,"confirmedTrackFrames":900}"#

    let decoded = try JSONDecoder().decode(
        PlayerDetectionStats.TrackingSummary.self,
        from: Data(json.utf8)
    )
    #expect(decoded.tracksConfirmed == 23)
    #expect(decoded.identity == nil)
}
