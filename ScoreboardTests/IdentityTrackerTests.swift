//
//  IdentityTrackerTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 11/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// The sampler with its default settings.
private let standardSampler = AppearanceSampler()

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

// MARK: - Checks after touching

private typealias Colour = (luma: UInt8, cb: UInt8, cr: UInt8)

private func appearance(shorts: Colour, feet: Colour) -> AppearanceSample {
    func solid(_ colour: Colour) -> [Float] {
        var histogram = [Float](repeating: 0, count: AppearanceSampler.binCount)
        histogram[standardSampler.bin(luma: colour.luma, cb: colour.cb, cr: colour.cr)] = 1
        return histogram
    }
    let black: Colour = (30, 128, 128)
    return AppearanceSample(
        bands: [solid(black), solid(black), solid(shorts), solid(black), solid(feet)],
        height: 0.25,
        footY: 0.375,
        aspect: 0.32
    )
}

/// Navy shorts and blue shoes.
private let personA = appearance(shorts: (45, 150, 120), feet: (80, 200, 100))
/// Black shorts and white shoes.
private let personB = appearance(shorts: (30, 128, 128), feet: (235, 128, 128))

/// Media time of a frame at 30 fps.
private func time(_ frame: Int) -> Double { Double(frame) / 30 }

/// A 1v1 where track 1 (looking like `first`) and track 2 (like `second`) are apart for
/// frames 1–20, then touch for frames 21–25.
private func touchedOneOnOne(first: AppearanceSample = personA, second: AppearanceSample = personB) -> IdentityTracker {
    var tracker = IdentityTracker(format: .oneOnOne)
    for frame in 1...20 {
        tracker.update(
            frameID: frame,
            timeSeconds: time(frame),
            tracks: [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)],
            samples: [1: first, 2: second]
        )
    }
    for frame in 21...25 {
        tracker.update(
            frameID: frame,
            timeSeconds: time(frame),
            tracks: [track(1, at: 0.48, first: 1, seen: frame), track(2, at: 0.52, first: 1, seen: frame)]
        )
    }
    return tracker
}

@Test("Players the tracker swapped while touching are swapped back from when they touched")
func swappedTracksAreCorrected() {
    var tracker = touchedOneOnOne()

    // Apart again, but each track has come out on the other person.
    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }
    for frame in 26...28 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personB, 2: personA])
    }

    // Three samples isn't enough to decide on.
    #expect(tracker.labels(for: apart(28)) == [1: "P1", 2: "P2"])
    #expect(tracker.summary.checks == 0)

    tracker.update(frameID: 29, timeSeconds: time(29), tracks: apart(29), samples: [1: personB, 2: personA])

    #expect(tracker.labels(for: apart(29)) == [1: "P2", 2: "P1"])
    #expect(tracker.summary.checks == 1)
    #expect(tracker.summary.swaps == 1)

    let record = tracker.record
    #expect(record.player(forTrack: 1, at: 20)?.number == 1)
    #expect(record.player(forTrack: 1, at: 21)?.number == 2)
    #expect(record.player(forTrack: 2, at: 20)?.number == 2)
    #expect(record.player(forTrack: 2, at: 30)?.number == 1)

    let check = record.checks.first
    #expect(record.checks.count == 1)
    #expect(check?.outcome == .swapped)
    #expect(check?.startFrame == 21)
    #expect(check?.frame == 29)
    #expect(check?.startTime == time(21))
    #expect(check?.time == time(29))
    #expect(check?.samples == [4, 4])
    #expect((check?.otherCost ?? .infinity) < (check?.keepCost ?? 0))
}

@Test("Players who come out of a touch as they went in keep their labels")
func unswappedTracksAreKept() {
    var tracker = touchedOneOnOne()

    let apart = { (frame: Int) in [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)] }
    for frame in 26...29 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personA, 2: personB])
    }

    #expect(tracker.labels(for: apart(29)) == [1: "P1", 2: "P2"])
    #expect(tracker.summary.checks == 1)
    #expect(tracker.summary.swaps == 0)
    #expect(tracker.summary.uncertain == 0)
    #expect(tracker.record.segments.count == 2)
    #expect(tracker.record.checks.map(\.outcome) == [.kept])
}

@Test("Two tracks lost in a touch and relinked the wrong way round are put right")
func wrongRelinksAreCorrected() {
    var tracker = touchedOneOnOne()

    // Both tracks are lost. The new ones come up nearer each other's last spot, so the
    // relink by position hands each the wrong player.
    let fresh = { (frame: Int) in [track(3, at: 0.62, first: 26, seen: frame), track(4, at: 0.38, first: 26, seen: frame)] }
    tracker.update(frameID: 26, tracks: fresh(26), samples: [3: personA, 4: personB])
    #expect(tracker.labels(for: fresh(26)) == [3: "P2", 4: "P1"])

    for frame in 27...29 {
        tracker.update(frameID: frame, tracks: fresh(frame), samples: [3: personA, 4: personB])
    }

    #expect(tracker.labels(for: fresh(29)) == [3: "P1", 4: "P2"])
    #expect(tracker.record.player(forTrack: 3, at: 26)?.number == 1)
    #expect(tracker.summary.relinks == 2)
    #expect(tracker.summary.swaps == 1)
}

@Test("When nothing has told the players apart, the labels stay and the stretch is marked uncertain")
func lookalikesAreMarkedUncertain() {
    // Identical in every band, so every cue scores a coin flip and counts for nothing.
    var tracker = touchedOneOnOne(first: personB, second: personB)

    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }
    for frame in 26...29 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personB, 2: personB])
    }

    // Settled at once: more samples of the same can't help.
    #expect(tracker.labels(for: apart(29)) == [1: "P1", 2: "P2"])
    #expect(tracker.summary.swaps == 0)
    #expect(tracker.summary.uncertain == 1)
    #expect(tracker.record.uncertain.first?.startFrame == 21)
    #expect(tracker.record.uncertain.first?.playerIDs.count == 2)

    let check = tracker.record.checks.first
    #expect(check?.outcome == .tooClose)
    #expect(check?.keepCost == nil)
}

/// Both players reading the same after a touch: half hidden, blurred.
private let blurred = appearance(shorts: (120, 128, 128), feet: (120, 128, 128))

@Test("A close call that never clears is marked uncertain at the sample limit")
func closeCallStopsAtLimit() {
    var tracker = touchedOneOnOne()

    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }
    for frame in 26...39 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: blurred, 2: blurred])
    }

    // Still asking at 14 samples.
    #expect(tracker.record.checks.isEmpty)

    tracker.update(frameID: 40, tracks: apart(40), samples: [1: blurred, 2: blurred])

    #expect(tracker.labels(for: apart(40)) == [1: "P1", 2: "P2"])
    #expect(tracker.summary.checks == 1)
    #expect(tracker.summary.uncertain == 1)

    let check = tracker.record.checks.first
    #expect(check?.outcome == .tooClose)
    #expect(check?.samples == [15, 15])
    #expect(check?.keepCost != nil)
    #expect(check?.keepCost == check?.otherCost)
}

@Test("A close call waits for more samples and decides once they make it clear")
func closeCallWaitsForEvidence() {
    var tracker = touchedOneOnOne()

    // Coming out of the touch, both read the same, then clearly — the wrong way round.
    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }

    for frame in 26...31 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: blurred, 2: blurred])
    }
    #expect(tracker.record.checks.isEmpty)
    #expect(tracker.labels(for: apart(31)) == [1: "P1", 2: "P2"])

    for frame in 32...40 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personB, 2: personA])
    }

    let check = tracker.record.checks.first
    #expect(tracker.record.checks.count == 1)
    #expect(check?.outcome == .swapped)
    #expect((check?.samples.min() ?? 0) > 6)
    #expect(tracker.labels(for: apart(40)) == [1: "P2", 2: "P1"])
    #expect(tracker.record.player(forTrack: 1, at: 21)?.number == 2)
}

@Test("A close call stops waiting when the timeout comes")
func closeCallTimesOut() {
    var tracker = touchedOneOnOne()

    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }

    // Five unclear samples, then they stay apart but are never clean again.
    for frame in 26...30 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: blurred, 2: blurred])
    }
    for frame in 31...115 {
        tracker.update(frameID: frame, tracks: apart(frame))
    }
    #expect(tracker.record.checks.isEmpty)

    for frame in 116...120 {
        tracker.update(frameID: frame, tracks: apart(frame))
    }
    #expect(tracker.record.checks.map(\.outcome) == [.tooClose])
    #expect(tracker.record.checks.first?.samples == [5, 5])
}

@Test("Players who never get a clear look in time are marked uncertain")
func unclearPlayersTimeOut() {
    var tracker = touchedOneOnOne()

    let apart = { (frame: Int) in [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)] }
    for frame in 26...110 {
        tracker.update(frameID: frame, tracks: apart(frame))
    }
    #expect(tracker.summary.uncertain == 0)

    for frame in 111...120 {
        tracker.update(frameID: frame, tracks: apart(frame))
    }
    #expect(tracker.summary.uncertain == 1)
    #expect(tracker.summary.checks == 0)

    let check = tracker.record.checks.first
    #expect(check?.outcome == .neverClear)
    #expect(check?.samples == [0, 0])
    #expect(check?.keepCost == nil)
}

@Test("Players who touch before there's a clean look at them are logged as having nothing to compare with")
func touchBeforeAnyLookIsLogged() {
    var tracker = IdentityTracker(format: .oneOnOne)
    let apart = { (frame: Int) in [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)] }

    // Two samples each — one short of a look.
    for frame in 1...2 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personA, 2: personB])
    }
    for frame in 3...5 {
        tracker.update(frameID: frame, tracks: [track(1, at: 0.48, first: 1, seen: frame), track(2, at: 0.52, first: 1, seen: frame)])
    }
    for frame in 6...9 {
        tracker.update(frameID: frame, tracks: apart(frame), samples: [1: personA, 2: personB])
    }

    #expect(tracker.record.checks.map(\.outcome) == [.noEarlierLook])
    #expect(tracker.summary.uncertain == 1)
}

@Test("Identity records and numbers saved before checks still load")
func recordsWithoutChecksLoad() throws {
    let record = #"{"format":"oneOnOne","players":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","number":1}],"segments":[{"trackID":1,"playerID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startFrame":1,"endFrame":10}]}"#
    let decodedRecord = try JSONDecoder().decode(IdentityRecord.self, from: Data(record.utf8))
    #expect(decodedRecord.segments.count == 1)
    #expect(decodedRecord.uncertain.isEmpty)
    #expect(decodedRecord.checks.isEmpty)

    let summary = #"{"playerCount":2,"playersSeen":2,"relinks":21,"unassignedTracks":4}"#
    let decodedSummary = try JSONDecoder().decode(IdentityTracker.Summary.self, from: Data(summary.utf8))
    #expect(decodedSummary.relinks == 21)
    #expect(decodedSummary.checks == 0)
    #expect(decodedSummary.uncertain == 0)
}

@Test("A change that hits both players alike doesn't drown out what tells them apart")
func sharedChangeDoesNotDilute() {
    let grey: Colour = (120, 128, 128)
    let black: Colour = (30, 128, 128)
    let navy: Colour = (45, 150, 120)

    /// Everything black but the shorts — or, after the touch, under different light.
    func person(shorts: Colour, rest: Colour) -> AppearanceSample {
        func solid(_ colour: Colour) -> [Float] {
            var histogram = [Float](repeating: 0, count: AppearanceSampler.binCount)
            histogram[standardSampler.bin(luma: colour.luma, cb: colour.cb, cr: colour.cr)] = 1
            return histogram
        }
        return AppearanceSample(
            bands: [solid(rest), solid(rest), solid(shorts), solid(rest), solid(rest)],
            height: 0.25,
            footY: 0.375,
            aspect: 0.32
        )
    }

    // Only the shorts tell them apart.
    var tracker = touchedOneOnOne(
        first: person(shorts: navy, rest: black),
        second: person(shorts: black, rest: black)
    )

    // Out of the touch swapped, and somewhere the light makes everything but the shorts
    // read grey for both of them. Unweighted, that shared change makes it too close to call.
    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }
    for frame in 26...29 {
        tracker.update(
            frameID: frame,
            tracks: apart(frame),
            samples: [1: person(shorts: black, rest: grey), 2: person(shorts: navy, rest: grey)]
        )
    }

    #expect(tracker.record.checks.map(\.outcome) == [.swapped])
    #expect(tracker.labels(for: apart(29)) == [1: "P2", 2: "P1"])
}

// MARK: - Why a check never got clear

/// Track 2 at x 0.7 on `frame`, matched at `confidence`, or coasting since frame 30.
private func playerTwo(_ frame: Int, confidence: Float = 0.9, coasting: Bool = false) -> PlayerTrack {
    var track = track(2, at: 0.7, first: 1, seen: coasting ? 30 : frame, state: coasting ? .coasting : .confirmed)
    track.confidence = confidence
    return track
}

@Test("While a check waits, each frame records why a player gave no clean sample")
func neverClearRecordsWhy() throws {
    var tracker = touchedOneOnOne()
    let playerOne = { (frame: Int) in track(1, at: 0.3, first: 1, seen: frame) }

    for frame in 26...30 {
        tracker.update(frameID: frame, tracks: [playerOne(frame), playerTwo(frame, confidence: 0.5)])
    }
    for frame in 31...35 {
        tracker.update(frameID: frame, tracks: [playerOne(frame), playerTwo(frame, coasting: true)])
    }
    // A second box with nobody on it, right beside them.
    for frame in 36...40 {
        tracker.update(
            frameID: frame,
            tracks: [playerOne(frame), playerTwo(frame), track(9, at: 0.74, first: 36, seen: frame)]
        )
    }
    // Then nobody's track is player two.
    for frame in 41...116 {
        tracker.update(frameID: frame, tracks: [playerOne(frame)])
    }

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .neverClear)

    let blocked = try #require(check.blocked)
    #expect(blocked[0] == IdentityCheck.Blocked(clean: 91))
    #expect(blocked[1] == IdentityCheck.Blocked(noTrack: 76, notMatched: 5, lowConfidence: 5, touchingNobody: 5))
}

@Test("Touching again starts the count over")
func touchingAgainResetsTheCount() throws {
    var tracker = touchedOneOnOne()
    let playerOne = { (frame: Int) in track(1, at: 0.3, first: 1, seen: frame) }

    for frame in 26...30 {
        tracker.update(frameID: frame, tracks: [playerOne(frame), playerTwo(frame, confidence: 0.5)])
    }
    for frame in 31...33 {
        tracker.update(
            frameID: frame,
            tracks: [track(1, at: 0.48, first: 1, seen: frame), track(2, at: 0.52, first: 1, seen: frame)]
        )
    }
    for frame in 34...124 {
        tracker.update(frameID: frame, tracks: [playerOne(frame), playerTwo(frame, confidence: 0.5)])
    }

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .neverClear)
    #expect(check.blocked?[1] == IdentityCheck.Blocked(lowConfidence: 91))
}

@Test("A check saved before reasons were recorded still loads")
func checkWithoutReasonsLoads() throws {
    let json = #"{"startFrame":21,"frame":116,"playerIDs":[],"outcome":"neverClear","samples":[30,0]}"#
    let check = try JSONDecoder().decode(IdentityCheck.self, from: Data(json.utf8))
    #expect(check.samples == [30, 0])
    #expect(check.blocked == nil)
}

// MARK: - Checking from one side

@Test("When one player stays hidden, the other's look alone settles a swap")
func hiddenPlayerSwapIsSettledFromOneSide() throws {
    var tracker = touchedOneOnOne()

    // Only track 1 comes out of the touch — and it's the person who was player two.
    let inView = { (frame: Int) in track(1, at: 0.7, first: 1, seen: frame) }
    for frame in 26...115 {
        tracker.update(frameID: frame, tracks: [inView(frame)], samples: [1: personB])
    }
    #expect(tracker.record.checks.isEmpty)

    tracker.update(frameID: 116, tracks: [inView(116)], samples: [1: personB])

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .swapped)
    #expect(check.oneSided == true)
    #expect(tracker.labels(for: [inView(116)]) == [1: "P2"])
    #expect(tracker.record.player(forTrack: 1, at: 20)?.number == 1)
    #expect(tracker.record.player(forTrack: 1, at: 21)?.number == 2)

    // The hidden person comes back by where they were last seen, and gets what's left.
    let returning = track(5, at: 0.5, first: 117, seen: 117)
    tracker.update(frameID: 117, tracks: [inView(117), returning], samples: [1: personB, 5: personA])
    #expect(tracker.labels(for: [inView(117), returning]) == [1: "P2", 5: "P1"])
}

@Test("A player whose track never got clear trades places when the other's look shows a swap")
func unclearTrackTradesOnOneSidedSwap() throws {
    var tracker = touchedOneOnOne()

    // Both tracks carry on, but track 2 is never confident enough to sample.
    let tracks = { (frame: Int) -> [PlayerTrack] in
        var unsure = track(2, at: 0.3, first: 1, seen: frame)
        unsure.confidence = 0.4
        return [track(1, at: 0.7, first: 1, seen: frame), unsure]
    }
    for frame in 26...116 {
        tracker.update(frameID: frame, tracks: tracks(frame), samples: [1: personB])
    }

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .swapped)
    #expect(check.oneSided == true)
    #expect(tracker.labels(for: tracks(116)) == [1: "P2", 2: "P1"])
}

@Test("When the one player in view is who they're labelled as, the labels stay")
func oneSidedCheckKeeps() throws {
    var tracker = touchedOneOnOne()

    let inView = { (frame: Int) in track(1, at: 0.3, first: 1, seen: frame) }
    for frame in 26...116 {
        tracker.update(frameID: frame, tracks: [inView(frame)], samples: [1: personA])
    }

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .kept)
    #expect(check.oneSided == true)
    #expect(tracker.labels(for: [inView(116)]) == [1: "P1"])
    #expect(tracker.summary.uncertain == 0)
}

@Test("A one-sided look that fits both players is too close to call")
func oneSidedCloseCall() throws {
    var tracker = touchedOneOnOne()

    let inView = { (frame: Int) in track(1, at: 0.7, first: 1, seen: frame) }
    for frame in 26...116 {
        tracker.update(frameID: frame, tracks: [inView(frame)], samples: [1: blurred])
    }

    let check = try #require(tracker.record.checks.first)
    #expect(check.outcome == .tooClose)
    #expect(check.oneSided == true)
    #expect(tracker.labels(for: [inView(116)]) == [1: "P1"])
}

// MARK: - End-of-run re-solve

@Test("Re-labelling a stretch of a track changes only that stretch")
func relabelChangesOnlyTheStretch() {
    let one = PlayerIdentity(id: UUID(), number: 1)
    let two = PlayerIdentity(id: UUID(), number: 2)
    var record = IdentityRecord(
        format: .oneOnOne,
        players: [one, two],
        segments: [IdentitySegment(trackID: 1, playerID: one.id, startFrame: 1, endFrame: 100)]
    )

    record.relabel(track: 1, from: 40, through: 60, to: two.id)

    #expect(record.player(forTrack: 1, at: 39)?.number == 1)
    #expect(record.player(forTrack: 1, at: 40)?.number == 2)
    #expect(record.player(forTrack: 1, at: 60)?.number == 2)
    #expect(record.player(forTrack: 1, at: 61)?.number == 1)
    #expect(record.player(forTrack: 1, at: 100)?.number == 1)
}

@Test("A swap the live check couldn't call is put right once the whole clip has been seen")
func resolvedRecordFixesAnUnsettledSwap() throws {
    var tracker = touchedOneOnOne()

    // They come out swapped. At first both read the same, so the live check gives up as
    // too close — then they're seen clearly for a second.
    let apart = { (frame: Int) in [track(1, at: 0.7, first: 1, seen: frame), track(2, at: 0.3, first: 1, seen: frame)] }
    for frame in 26...40 {
        tracker.update(frameID: frame, timeSeconds: time(frame), tracks: apart(frame), samples: [1: blurred, 2: blurred])
    }
    #expect(tracker.record.checks.map(\.outcome) == [.tooClose])

    for frame in 41...70 {
        tracker.update(frameID: frame, timeSeconds: time(frame), tracks: apart(frame), samples: [1: personB, 2: personA])
    }

    let resolved = tracker.resolvedRecord()

    #expect(resolved.player(forTrack: 1, at: 50)?.number == 2)
    #expect(resolved.player(forTrack: 2, at: 50)?.number == 1)
    #expect(resolved.player(forTrack: 1, at: 10)?.number == 1)
    #expect(resolved.revisions?.count == 1)
    #expect(resolved.revisions?.first?.startFrame == 26)

    // The live record is left as it was, so asking again gives the same answer.
    #expect(tracker.record.player(forTrack: 1, at: 50)?.number == 1)
    #expect(tracker.resolvedRecord() == resolved)
}

@Test("When the live labels already hold up, the re-solve moves nothing")
func resolvedRecordLeavesGoodLabels() {
    var tracker = touchedOneOnOne()
    let apart = { (frame: Int) in [track(1, at: 0.3, first: 1, seen: frame), track(2, at: 0.7, first: 1, seen: frame)] }
    for frame in 26...50 {
        tracker.update(frameID: frame, timeSeconds: time(frame), tracks: apart(frame), samples: [1: personA, 2: personB])
    }

    let resolved = tracker.resolvedRecord()

    #expect(resolved.revisions == [])
    #expect(resolved.segments == tracker.record.segments)
}
