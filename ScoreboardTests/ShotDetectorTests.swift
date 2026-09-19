//
//  ShotDetectorTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 19/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

// MARK: - Fixtures

/// A rim roughly where one sits in a courtside frame: centred, upper third, and
/// foreshortened vertically the way a real hoop is from below.
private let testRim = HoopGeometry(
    center: CGPoint(x: 0.5, y: 0.70),
    verticalRadius: 0.012,
    horizontalRadius: 0.045
)

private let ballRadius: CGFloat = 0.022

/// Synthesise a ballistic arc in Vision space (origin bottom-left, y up).
///
/// - Parameters:
///   - fromX/fromY: release point
///   - peakY: apex height
///   - landX: where the ball crosses back down through `fromY`
private func ballisticArc(
    startFrame: Int,
    frames: Int,
    fromX: Double,
    fromY: Double,
    peakY: Double,
    landX: Double,
    radius: CGFloat = ballRadius
) -> [BallObservation] {

    // y(τ) = fromY + 4·(peakY - fromY)·s·(1 - s) with s = τ/frames — a parabola through
    // (0, fromY), peaking at s = 0.5, back to fromY at s = 1.
    (0...frames).map { step in
        let s = Double(step) / Double(frames)
        let x = fromX + (landX - fromX) * s
        let y = fromY + 4.0 * (peakY - fromY) * s * (1.0 - s)

        return BallObservation(
            frameID: startFrame + step,
            center: CGPoint(x: x, y: y),
            radius: radius,
            confidence: 0.9
        )
    }
}

/// A shot arc that comes down through the rim plane at exactly `crossingX`.
///
/// Specifying the landing point instead would be misleading: the ball passes the rim
/// plane well before it returns to release height, so the two x values are far apart.
/// Tests care about where it crosses the ring, so that is what this takes.
private func shotArc(
    startFrame: Int = 0,
    frames: Int = 30,
    fromX: Double = 0.15,
    fromY: Double = 0.35,
    peakY: Double = 0.88,
    crossingX: Double,
    planeY: Double = Double(testRim.center.y)
) -> [BallObservation] {

    // Descending root of fromY + 4·(peakY - fromY)·s·(1 - s) = planeY
    let ratio = (planeY - fromY) / (peakY - fromY)
    let sCross = (1.0 + (1.0 - ratio).squareRoot()) / 2.0

    // Choose the landing x so that x(sCross) == crossingX.
    let landX = fromX + (crossingX - fromX) / sCross

    return ballisticArc(
        startFrame: startFrame,
        frames: frames,
        fromX: fromX,
        fromY: fromY,
        peakY: peakY,
        landX: landX
    )
}

private func run(
    _ observations: [BallObservation],
    rim: HoopGeometry? = testRim,
    config: ShotDetectorConfig = ShotDetectorConfig()
) -> (detector: ShotDetector, events: [ShotEvent]) {

    var detector = ShotDetector(config: config)
    var events: [ShotEvent] = []

    for observation in observations {
        events.append(contentsOf: detector.process(observation: observation, rim: rim))
    }

    return (detector, events)
}

private func resolvedAttempts(_ events: [ShotEvent]) -> [ShotAttempt] {
    events.compactMap {
        if case .attemptResolved(let attempt) = $0 { return attempt }
        return nil
    }
}

// MARK: - Trajectory maths

struct MotionFitTests {

    @Test("Fit recovers a known parabola even at high absolute frame numbers")
    func fitIsStableAtLargeFrameIDs() throws {
        // Absolute frame IDs in the thousands used to destroy the quadratic
        // coefficient through floating-point cancellation.
        let arc = ballisticArc(
            startFrame: 48_000, frames: 20,
            fromX: 0.2, fromY: 0.3, peakY: 0.8, landX: 0.7
        )

        let fit = try #require(fitMotionWeighted(arc))

        #expect(fit.isBallistic)
        #expect(fit.rmse < 1e-6)

        let apex = try #require(predictApex(fit: fit))
        #expect(abs(apex.y - 0.8) < 1e-3)
    }

    @Test("Gravity gives a negative quadratic coefficient in Vision coordinates")
    func gravityOpensDownward() throws {
        let arc = ballisticArc(
            startFrame: 0, frames: 16,
            fromX: 0.3, fromY: 0.2, peakY: 0.9, landX: 0.6
        )
        let fit = try #require(fitMotionWeighted(arc))
        #expect(fit.py.0 < 0)
    }

    @Test("Downward crossing is found analytically, with sub-frame precision")
    func findsDescendingCrossing() throws {
        let arc = ballisticArc(
            startFrame: 100, frames: 20,
            fromX: 0.2, fromY: 0.3, peakY: 0.9, landX: 0.8
        )
        let fit = try #require(fitMotionWeighted(arc))

        let crossing = try #require(
            findDownwardCrossing(fit: fit, yTarget: 0.70, after: 100, before: 160)
        )

        // Must be on the way down.
        #expect(predictVelocity(fit: fit, t: crossing).vy < 0)
        #expect(abs(predictPosition(fit: fit, t: crossing).y - 0.70) < 1e-6)

        // Not snapped to an integer frame.
        #expect(crossing != crossing.rounded())
    }

    @Test("A rising ball has no downward crossing above it")
    func noCrossingWhileRising() throws {
        let arc = ballisticArc(
            startFrame: 0, frames: 30,
            fromX: 0.2, fromY: 0.2, peakY: 0.5, landX: 0.5
        )
        let fit = try #require(fitMotionWeighted(arc))

        // The arc never reaches 0.9, so there is nothing to cross.
        #expect(findDownwardCrossing(fit: fit, yTarget: 0.9, after: 0, before: 60) == nil)
    }

    @Test("Fit rejects a window with no time span")
    func rejectsDuplicateFrames() {
        let repeated = (0..<8).map { _ in
            BallObservation(frameID: 42, center: CGPoint(x: 0.5, y: 0.5), radius: 0.02, confidence: 0.9)
        }
        #expect(fitMotionWeighted(repeated) == nil)
    }
}

// MARK: - Rim geometry

struct HoopGeometryTests {

    @Test("Geometry is built from the box centre, not a corner")
    func centreFromBoundingBox() {
        let box = CGRect(x: 0.4, y: 0.6, width: 0.1, height: 0.03)
        let hoop = HoopGeometry(boundingBox: box)

        #expect(abs(hoop.center.x - 0.45) < 1e-9)
        #expect(abs(hoop.center.y - 0.615) < 1e-9)
        #expect(abs(hoop.horizontalRadius - 0.05) < 1e-9)
        #expect(hoop.leftX < hoop.center.x)
        #expect(hoop.rightX > hoop.center.x)
    }

    @Test("Rim tracker smooths jitter and ignores a distant second hoop")
    func rimTrackerRejectsOutliers() throws {
        var tracker = RimTracker()

        for frame in 0..<10 {
            let jitter = Double(frame % 3) * 0.001
            tracker.observe(
                boundingBox: CGRect(x: 0.45 + jitter, y: 0.69, width: 0.09, height: 0.024),
                frameID: frame
            )
        }

        let settled = try #require(tracker.geometry)
        #expect(abs(settled.center.x - 0.496) < 0.01)

        // A hoop at the far end of the court must not drag the scoring plane.
        let accepted = tracker.observe(
            boundingBox: CGRect(x: 0.05, y: 0.69, width: 0.09, height: 0.024),
            frameID: 11
        )
        #expect(accepted == false)
        #expect(tracker.geometry?.center.x == settled.center.x)
    }

    @Test("View-space placement round-trips through Vision space")
    func placementRoundTrip() {
        // A rim in the upper third of the frame. In view space (y down) that is a small
        // y; in Vision space (y up) it must come back as a large one.
        let drawn = CGRect(x: 0.42, y: 0.24, width: 0.11, height: 0.03)

        let geometry = HoopGeometry(normalizedViewRect: drawn)

        // Flipped, not mirrored about the wrong axis: view y 0.24-0.27 maps to
        // Vision y 0.73-0.76, so the rim stays high in the frame.
        #expect(abs(geometry.center.y - 0.745) < 1e-9)
        #expect(abs(geometry.center.x - 0.475) < 1e-9)
        #expect(abs(geometry.horizontalRadius - 0.055) < 1e-9)
        #expect(abs(geometry.verticalRadius - 0.015) < 1e-9)

        // Reopening the editor must redraw exactly the box that was drawn.
        let reopened = geometry.normalizedViewRect
        #expect(abs(reopened.minX - drawn.minX) < 1e-9)
        #expect(abs(reopened.minY - drawn.minY) < 1e-9)
        #expect(abs(reopened.width - drawn.width) < 1e-9)
        #expect(abs(reopened.height - drawn.height) < 1e-9)
    }

    @Test("A placed rim scores a shot through it")
    func placedRimDrivesVerdict() {
        // Place a rim by hand where testRim sits, then confirm the detector scores
        // against it exactly as it would a detected one.
        var tracker = RimTracker()
        tracker.setUserPlaced(HoopGeometry(normalizedViewRect: CGRect(
            x: 0.455, y: 0.288, width: 0.09, height: 0.024
        )))

        let placed = tracker.geometry!
        let arc = shotArc(crossingX: Double(placed.center.x), planeY: Double(placed.center.y))

        let attempts = resolvedAttempts(run(arc, rim: placed).events)
        #expect(attempts.count == 1)
        #expect(attempts.first?.result == .made)
    }

    @Test("A hand-placed rim outranks the detector")
    func userPlacementWins() throws {
        var tracker = RimTracker()

        tracker.observe(
            boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024),
            frameID: 0
        )
        #expect(tracker.isUserPlaced == false)

        let placed = HoopGeometry(
            center: CGPoint(x: 0.62, y: 0.55),
            verticalRadius: 0.013,
            horizontalRadius: 0.05
        )
        tracker.setUserPlaced(placed)

        #expect(tracker.isUserPlaced)
        #expect(tracker.isLocked)
        #expect(tracker.geometry == placed)

        // Later detections must not drag the plane off the user's placement.
        let accepted = tracker.observe(
            boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024),
            frameID: 5
        )
        #expect(accepted == false)
        #expect(tracker.geometry == placed)
    }

    @Test("Rim publishes from the very first detection")
    func publishesImmediately() {
        var tracker = RimTracker()
        tracker.observe(
            boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024),
            frameID: 0
        )
        // Detections are scarce; withholding the rim until several agree can mean no
        // scoring plane for most of a clip.
        #expect(tracker.geometry != nil)
    }

    @Test("One bad first detection does not lock out the real rim")
    func earlyOutlierDoesNotPoison() throws {
        var tracker = RimTracker()

        // A rogue first box on the far side of the frame.
        tracker.observe(boundingBox: CGRect(x: 0.02, y: 0.2, width: 0.09, height: 0.024), frameID: 0)

        // The real rim then shows up repeatedly and must be able to take over.
        for frame in 1...8 {
            tracker.observe(
                boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024),
                frameID: frame
            )
        }

        let settled = try #require(tracker.geometry)
        #expect(abs(settled.center.x - 0.495) < 0.01)
        #expect(abs(settled.center.y - 0.702) < 0.01)
    }

    @Test("Clearing a placement hands control back to the detector")
    func clearingPlacement() {
        var tracker = RimTracker()
        tracker.setUserPlaced(
            HoopGeometry(center: CGPoint(x: 0.6, y: 0.5), verticalRadius: 0.01, horizontalRadius: 0.04)
        )
        tracker.clearUserPlacement()

        #expect(tracker.isUserPlaced == false)
        #expect(tracker.geometry == nil)

        let accepted = tracker.observe(
            boundingBox: CGRect(x: 0.45, y: 0.69, width: 0.09, height: 0.024),
            frameID: 1
        )
        #expect(accepted)
        #expect(tracker.geometry != nil)
    }
}

// MARK: - Shot outcomes

struct ShotDetectorTests {

    @Test("A shot through the middle of the ring is a make")
    func cleanMake() throws {
        // Released low, peaks well above the rim, drops through the middle of the ring.
        let arc = shotArc(crossingX: 0.5)

        let (_, events) = run(arc)
        let attempts = resolvedAttempts(events)

        #expect(attempts.count == 1)
        #expect(attempts.first?.result == .made)

        let crossing = try #require(attempts.first?.scoringCrossing)
        #expect(abs(crossing.normalisedOffset) < 0.5)
    }

    @Test("A shot that comes down well outside the ring is a miss")
    func clearMiss() throws {
        // Same flight, but crossing the plane two rim radii right of centre.
        let arc = shotArc(crossingX: 0.5 + 0.09)

        let (_, events) = run(arc)
        let attempts = resolvedAttempts(events)

        #expect(attempts.count == 1)
        #expect(attempts.first?.result == .missed)
        #expect(attempts.first?.scoringCrossing == nil)
    }

    @Test("Dribbling below the rim never opens an attempt")
    func dribblingIsNotAShot() {
        // Four bounces peaking around waist height, directly under the hoop — the
        // worst case for a detector that keys on curvature alone.
        var observations: [BallObservation] = []
        for bounce in 0..<4 {
            observations += ballisticArc(
                startFrame: bounce * 13,
                frames: 12,
                fromX: 0.48 + Double(bounce) * 0.01,
                fromY: 0.10,
                peakY: 0.30,
                landX: 0.50 + Double(bounce) * 0.01
            )
        }

        let (detector, events) = run(observations)

        #expect(resolvedAttempts(events).isEmpty)
        #expect(detector.currentAttempt == nil)
    }

    @Test("A chest pass across the frame at rim height is not a shot")
    func flatPassIsNotAShot() {
        // Crosses the rim's x, but arrives almost flat and never peaks above the ring.
        let arc = ballisticArc(
            startFrame: 0, frames: 26,
            fromX: 0.1, fromY: 0.66, peakY: 0.70, landX: 0.9
        )

        let (_, events) = run(arc)
        #expect(resolvedAttempts(events).isEmpty)
    }

    @Test("A shot picked up on its way down still resolves")
    func lateDetection() throws {
        // Start the observations after the apex: only the descent is visible.
        let descentOnly = Array(shotArc(crossingX: 0.5).dropFirst(18))

        let (_, events) = run(descentOnly)
        let attempts = resolvedAttempts(events)

        #expect(attempts.count == 1)
        #expect(attempts.first?.result == .made)
        #expect(attempts.first?.wasDetectedLate == true)
    }

    @Test("One flight produces exactly one attempt")
    func noDoubleCounting() {
        // A make, then the ball bounces on the floor under the hoop — which used to be
        // able to open a second attempt.
        var observations = shotArc(crossingX: 0.5)
        observations += ballisticArc(
            startFrame: 31, frames: 14,
            fromX: 0.5, fromY: 0.08, peakY: 0.34, landX: 0.55
        )

        let (_, events) = run(observations)
        #expect(resolvedAttempts(events).count == 1)
    }

    @Test("Repeated observations for one frame are ignored")
    func duplicateFrameIsDropped() {
        var detector = ShotDetector()
        let observation = BallObservation(
            frameID: 7, center: CGPoint(x: 0.5, y: 0.5), radius: 0.02, confidence: 0.9
        )

        detector.process(observation: observation, rim: testRim)
        detector.process(observation: observation, rim: testRim)

        #expect(detector.history.count == 1)
    }

    @Test("With no rim detected nothing is decided")
    func noRimNoVerdict() {
        let arc = shotArc(crossingX: 0.5)

        let (detector, events) = run(arc, rim: nil)

        #expect(events.isEmpty)
        #expect(detector.currentAttempt == nil)
        // History still accumulates, so the fit is warm the moment a rim appears.
        #expect(detector.history.isEmpty == false)
    }

    @Test("An attempt whose ball disappears is abandoned, not scored")
    func lostBallIsAbandoned() throws {
        // Rising toward the rim, then the track dies before the outcome.
        let truncated = Array(shotArc(crossingX: 0.5).prefix(14))

        var detector = ShotDetector()
        var events: [ShotEvent] = []
        for observation in truncated {
            events.append(contentsOf: detector.process(observation: observation, rim: testRim))
        }
        events.append(contentsOf: detector.flush(atFrame: 14))

        let attempts = resolvedAttempts(events)
        #expect(attempts.count == 1)
        #expect(attempts.first?.result == .abandoned)
    }

    @Test("Make tolerance widens and narrows with configuration")
    func makeToleranceIsTunable() {
        // Crosses near the rim edge, 0.034 from centre. The usable half-width is
        // 0.045 - (0.022 × clearance), so strict (0.023) rejects and lenient (0.045)
        // accepts the very same flight.
        let arc = shotArc(crossingX: 0.5 + 0.034)

        var strict = ShotDetectorConfig()
        strict.makeBallClearance = 1.0

        var lenient = ShotDetectorConfig()
        lenient.makeBallClearance = 0.0

        let strictResult = resolvedAttempts(run(arc, config: strict).events).first
        let lenientResult = resolvedAttempts(run(arc, config: lenient).events).first

        #expect(strictResult?.result == .missed)
        #expect(lenientResult?.result == .made)
    }
}

// MARK: - Aggregation

@MainActor
struct GameStateTests {

    @Test("Stats count resolved attempts and ignore abandoned ones")
    func statsAggregation() {
        let state = GameState()

        func attempt(_ result: ShotAttempt.Result) -> ShotAttempt {
            ShotAttempt(
                id: UUID(), startFrame: 0, endFrame: 10, result: result,
                trajectory: [], crossings: [], rimContacts: 0,
                apexY: nil, wasDetectedLate: false
            )
        }

        state.handle(.attemptResolved(attempt(.made)))
        state.handle(.attemptResolved(attempt(.missed)))
        state.handle(.attemptResolved(attempt(.made)))
        state.handle(.attemptResolved(attempt(.abandoned)))

        #expect(state.stats.attempts == 3)
        #expect(state.stats.makes == 2)
        #expect(state.stats.misses == 1)
        #expect(state.stats.points == 4)
        #expect(abs(state.stats.fieldGoalPercentage - 66.667) < 0.01)
        #expect(state.abandonedAttempts.count == 1)
        #expect(state.shotTimeline.count == 3)
    }

    @Test("Out-of-order snapshots are dropped")
    func snapshotOrdering() {
        let state = GameState()

        state.apply(GameSnapshot(sequence: 5, frameID: 50))
        state.apply(GameSnapshot(sequence: 3, frameID: 30))

        #expect(state.snapshot.frameID == 50)
    }
}

// MARK: - Rim box editing

struct RimBoxEditorTests {

    private let bounds = CGSize(width: 1000, height: 600)
    private let box = CGRect(x: 400, y: 200, width: 200, height: 60)
    private let hitRadius: CGFloat = 24

    @Test("With no box, any drag starts a new one")
    func noBoxMeansDraw() {
        #expect(RimBoxEditor.classify(point: CGPoint(x: 10, y: 10), box: nil, hitRadius: hitRadius) == .draw)
    }

    @Test("Each mid-edge bubble is grabbed by its own handle")
    func handlesAreHit() {
        for handle in RimBoxEditor.Handle.allCases {
            let grab = RimBoxEditor.classify(
                point: handle.point(in: box), box: box, hitRadius: hitRadius
            )
            #expect(grab == .resize(handle))
        }
    }

    @Test("A grab near a corner resizes rather than moves")
    func handlesWinOverBody() {
        // Just inside the box but within reach of the leading handle.
        let nearLeadingEdge = CGPoint(x: box.minX + 6, y: box.midY)
        #expect(
            RimBoxEditor.classify(point: nearLeadingEdge, box: box, hitRadius: hitRadius)
            == .resize(.leading)
        )
    }

    @Test("The box body moves, and empty space pans")
    func bodyMovesAndOutsidePans() {
        #expect(RimBoxEditor.classify(point: CGPoint(x: 500, y: 230), box: box, hitRadius: hitRadius) == .move)
        #expect(RimBoxEditor.classify(point: CGPoint(x: 80, y: 500), box: box, hitRadius: hitRadius) == .pan)
    }

    @Test("Resizing one edge leaves the other three alone")
    func resizeMovesOnlyOneEdge() {
        let widened = RimBoxEditor.apply(
            grab: .resize(.trailing), origin: box,
            translation: CGSize(width: 50, height: 0),
            bounds: bounds, minimumSide: 8
        )

        #expect(widened.maxX == box.maxX + 50)
        #expect(widened.minX == box.minX)
        #expect(widened.minY == box.minY)
        #expect(widened.height == box.height)
    }

    @Test("An edge cannot be dragged through its opposite")
    func edgesCannotInvert() {
        // Yank the leading edge far past the trailing one.
        let collapsed = RimBoxEditor.apply(
            grab: .resize(.leading), origin: box,
            translation: CGSize(width: 10_000, height: 0),
            bounds: bounds, minimumSide: 8
        )

        #expect(collapsed.width == 8)
        #expect(collapsed.width > 0)
        #expect(collapsed.maxX == box.maxX)
    }

    @Test("Edges stay inside the frame")
    func edgesStayInBounds() {
        let pushedOut = RimBoxEditor.apply(
            grab: .resize(.leading), origin: box,
            translation: CGSize(width: -10_000, height: 0),
            bounds: bounds, minimumSide: 8
        )
        #expect(pushedOut.minX == 0)

        let pushedDown = RimBoxEditor.apply(
            grab: .resize(.bottom), origin: box,
            translation: CGSize(width: 0, height: 10_000),
            bounds: bounds, minimumSide: 8
        )
        #expect(pushedDown.maxY == bounds.height)
    }

    @Test("Moving keeps the box's size and stops at the frame edge")
    func moveClampsWithoutResizing() {
        let shoved = RimBoxEditor.apply(
            grab: .move, origin: box,
            translation: CGSize(width: 10_000, height: 10_000),
            bounds: bounds, minimumSide: 8
        )

        // Size preserved — a clamp that shrank the box would silently change the rim.
        #expect(shoved.width == box.width)
        #expect(shoved.height == box.height)
        #expect(shoved.maxX == bounds.width)
        #expect(shoved.maxY == bounds.height)
    }

    @Test("A move and its inverse return the box exactly")
    func moveIsReversible() {
        let there = RimBoxEditor.apply(
            grab: .move, origin: box, translation: CGSize(width: 37, height: -21),
            bounds: bounds, minimumSide: 8
        )
        let back = RimBoxEditor.apply(
            grab: .move, origin: there, translation: CGSize(width: -37, height: 21),
            bounds: bounds, minimumSide: 8
        )
        #expect(back == box)
    }

    @Test("Resizing an edge moves the rim centre by half the change")
    func resizeShiftsCentreAsExpected() {
        // The centre is the scoring plane, so where it lands after a resize is the
        // thing that actually drives verdicts.
        let widened = RimBoxEditor.apply(
            grab: .resize(.trailing), origin: box,
            translation: CGSize(width: 40, height: 0),
            bounds: bounds, minimumSide: 8
        )
        #expect(widened.midX == box.midX + 20)
        #expect(widened.midY == box.midY)
    }
}
