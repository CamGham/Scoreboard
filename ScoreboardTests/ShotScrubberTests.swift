//
//  ShotScrubberTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 20/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

// MARK: - Fixtures

private let scrubberRim = HoopGeometry(
    center: CGPoint(x: 0.5, y: 0.70),
    verticalRadius: 0.012,
    horizontalRadius: 0.045
)

/// A resolved attempt whose crossing — and so whose key time — sits at `crossingAt`.
///
/// `startTime` and `endTime` come from the trajectory, so the sightings are spread either
/// side of the crossing the way a real arc's would be.
private func attempt(
    crossingAt: Double?,
    from start: Double,
    to end: Double,
    result: ShotAttempt.Result = .made,
    verdict: ShotAttempt.UserVerdict? = nil
) -> ShotAttempt {

    let steps = 10
    let trajectory = (0...steps).map { step -> BallObservation in
        let fraction = Double(step) / Double(steps)
        return BallObservation(
            frameID: step,
            center: CGPoint(x: 0.3 + fraction * 0.3, y: 0.4),
            radius: 0.02,
            confidence: 0.9,
            timeSeconds: start + fraction * (end - start)
        )
    }

    let crossings: [RimCrossing] = crossingAt.map {
        [RimCrossing(frame: 10, x: 0.5, normalisedOffset: 0.2, isClean: true, timeSeconds: $0)]
    } ?? []

    return ShotAttempt(
        id: UUID(),
        startFrame: 0,
        endFrame: steps,
        result: result,
        trajectory: trajectory,
        crossings: crossings,
        rimContacts: 0,
        apexY: 0.8,
        wasDetectedLate: false,
        rim: scrubberRim,
        userVerdict: verdict
    )
}

/// A marker at a given time, for the snapping tests where nothing else matters.
private func marker(at time: Double, ordinal: Int = 1) -> ShotMarker {
    ShotMarker(
        id: UUID(),
        ordinal: ordinal,
        time: time,
        window: (time - 1)...(time + 1),
        result: .made,
        isNotAShot: false,
        isCorrected: false,
        isCloseCall: false
    )
}

// MARK: - Building markers

@Test("Markers are ordered by time and numbered in playing order")
func markersAreOrderedAndNumbered() {
    let attempts = [
        attempt(crossingAt: 40, from: 38, to: 41),
        attempt(crossingAt: 10, from: 8, to: 11),
        attempt(crossingAt: 25, from: 23, to: 26)
    ]

    let markers = ShotMarker.markers(from: attempts, duration: 60)

    #expect(markers.map(\.time) == [10, 25, 40])
    #expect(markers.map(\.ordinal) == [1, 2, 3])
}

@Test("An attempt with no seekable moment is left off the bar")
func untimedAttemptsAreDropped() {
    // No crossing and no trajectory times: nothing to seek to, so a marker would be a
    // guess rather than a landmark.
    let untimed = ShotAttempt(
        id: UUID(),
        startFrame: 0,
        endFrame: 10,
        result: .missed,
        trajectory: [BallObservation(frameID: 0, center: .zero, radius: 0.02, confidence: 0.5)],
        crossings: [],
        rimContacts: 0,
        apexY: nil,
        wasDetectedLate: false,
        rim: scrubberRim,
        userVerdict: nil
    )

    let markers = ShotMarker.markers(from: [untimed, attempt(crossingAt: 12, from: 10, to: 13)], duration: 60)

    #expect(markers.count == 1)
    #expect(markers[0].time == 12)
}

@Test("A shot's window is padded but stays inside the clip")
func windowsArePaddedAndClamped() {
    let markers = ShotMarker.markers(
        from: [attempt(crossingAt: 0.2, from: 0.1, to: 0.4), attempt(crossingAt: 59.6, from: 59.4, to: 59.9)],
        duration: 60,
        padding: 0.75
    )

    #expect(markers[0].window.lowerBound == 0)
    #expect(markers[1].window.upperBound <= 60)
}

@Test("A ruling recolours the marker, so the bar shows the corrected outcome")
func verdictDrivesMarkerColour() {
    let corrected = attempt(crossingAt: 10, from: 8, to: 11, result: .made, verdict: .missed)
    let dismissed = attempt(crossingAt: 20, from: 18, to: 21, result: .made, verdict: .notAShot)

    let markers = ShotMarker.markers(from: [corrected, dismissed], duration: 30)

    #expect(markers[0].result == .missed)
    #expect(markers[0].isCorrected)
    #expect(markers[1].isNotAShot)
}

// MARK: - Snapping

@Test("A scrub inside the snap radius lands exactly on the shot")
func snapsToNearbyMarker() {
    let markers = [marker(at: 10), marker(at: 30, ordinal: 2)]

    let target = ShotMarker.snapTarget(for: 10.8, in: markers, within: 1.0)

    #expect(target?.time == 10)
}

@Test("A scrub outside the radius is left where the finger put it")
func doesNotSnapBeyondRadius() {
    let markers = [marker(at: 10)]

    #expect(ShotMarker.snapTarget(for: 12.5, in: markers, within: 1.0) == nil)
}

@Test("Between two shots, the nearer one wins")
func snapsToNearestOfSeveral() {
    let markers = [marker(at: 10), marker(at: 12, ordinal: 2)]

    #expect(ShotMarker.snapTarget(for: 11.4, in: markers, within: 2.0)?.time == 12)
    #expect(ShotMarker.snapTarget(for: 10.6, in: markers, within: 2.0)?.time == 10)
}

@Test("Nothing to snap to on a clip with no detected shots")
func noMarkersMeansNoSnap() {
    #expect(ShotMarker.snapTarget(for: 12, in: [], within: 2.0) == nil)
}

// MARK: - Positioning inside a shot

/// Markers with a realistic padded window either side of the key moment.
private func windowedMarker(at time: Double, ordinal: Int = 1) -> ShotMarker {
    ShotMarker(
        id: UUID(),
        ordinal: ordinal,
        time: time,
        window: (time - 1.2)...(time + 0.75),
        result: .made,
        isNotAShot: false,
        isCorrected: false,
        isCloseCall: false
    )
}

@Test("The shot the playhead is inside is the one the detail bar opens on")
func anchorIsTheShotYouAreIn() {
    let markers = [windowedMarker(at: 12), windowedMarker(at: 40, ordinal: 2)]

    // Mid-flight in the first shot.
    #expect(ShotMarker.anchor(at: 11.4, in: markers)?.time == 12)

    // In the run-up, which is inside the padded window.
    #expect(ShotMarker.anchor(at: 11.0, in: markers)?.time == 12)

    // Between shots: no shot to open on.
    #expect(ShotMarker.anchor(at: 25, in: markers) == nil)
}

@Test("Where windows overlap, the nearer key moment wins")
func anchorPicksTheNearerShot() {
    let first = windowedMarker(at: 12)
    let second = windowedMarker(at: 12.9, ordinal: 2)

    #expect(ShotMarker.anchor(at: 12.8, in: [first, second])?.time == 12.9)
    #expect(ShotMarker.anchor(at: 12.1, in: [first, second])?.time == 12)
}

@Test("Every route to a shot lands in the same place")
func landingIsShared() {
    let shot = windowedMarker(at: 12)

    // Tapping the bar, scrubbing onto it and the shot-to-shot buttons all read this, so
    // they can't drift apart. Flipping `ShotMarker.landing` moves all three at once.
    switch ShotMarker.landing {
    case .keyMoment:
        #expect(shot.landingTime == shot.time)
    case .runUp:
        #expect(shot.landingTime == shot.window.lowerBound)
    }
}

// MARK: - Stepping shot to shot

private let threeShots = [
    windowedMarker(at: 12),
    windowedMarker(at: 40, ordinal: 2),
    windowedMarker(at: 75, ordinal: 3)
]

@Test("Standing on a shot, the previous button goes to the shot before it")
func previousFromAShotGoesBack() {
    // The bug: landing on a shot puts the playhead on its key moment, which is *after*
    // its own window start — so a test written against window starts picked the shot you
    // were already standing on and the button did nothing.
    let standingOnSecond = threeShots[1].landingTime

    #expect(ShotMarker.previous(before: standingOnSecond, in: threeShots)?.ordinal == 1)
}

@Test("Standing on a shot, the next button goes to the one after it")
func nextFromAShotGoesForward() {
    #expect(ShotMarker.next(after: threeShots[1].landingTime, in: threeShots)?.ordinal == 3)
}

@Test("Anywhere inside a shot counts as being on it, not before it")
func insideTheWindowStepsByShot() {
    // In the run-up of the second shot: forward is the third shot, not this one's own
    // crossing a moment ahead.
    let inRunUp = threeShots[1].window.lowerBound + 0.1

    #expect(ShotMarker.next(after: inRunUp, in: threeShots)?.ordinal == 3)
    #expect(ShotMarker.previous(before: inRunUp, in: threeShots)?.ordinal == 1)
}

@Test("Between shots, the buttons take the nearest one either way")
func betweenShotsStepsToNearest() {
    #expect(ShotMarker.next(after: 25, in: threeShots)?.ordinal == 2)
    #expect(ShotMarker.previous(before: 25, in: threeShots)?.ordinal == 1)
}

@Test("The ends of the clip have nowhere further to go")
func endsOfTheClipHaveNoNeighbour() {
    #expect(ShotMarker.previous(before: threeShots[0].landingTime, in: threeShots) == nil)
    #expect(ShotMarker.next(after: threeShots[2].landingTime, in: threeShots) == nil)
    #expect(ShotMarker.next(after: 5, in: [])  == nil)
}
