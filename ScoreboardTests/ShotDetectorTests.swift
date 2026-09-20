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

// MARK: - Ball ROI

struct BallROIPredictorTests {

    /// 16:9, the shape almost all of this footage is.
    private let aspect = 16.0 / 9.0

    @Test("The crop is square in pixels, not in normalized units")
    func cropIsPixelSquare() {
        let roi = BallROIPredictor.regionOfInterest(
            around: CGPoint(x: 0.5, y: 0.5), sideFraction: 0.25, aspect: aspect
        )

        // A normalized square on a 16:9 frame is a wide rectangle, which would hand back
        // the letterboxing the crop exists to avoid. Height must be scaled by aspect.
        #expect(abs(roi.width - 0.25) < 1e-9)
        #expect(abs(roi.height - 0.25 * aspect) < 1e-9)

        // Equal extent in pixels on a 1920x1080 frame.
        #expect(abs((roi.width * 1920) - (roi.height * 1080)) < 1e-6)
    }

    @Test("The crop stays inside the frame without shrinking")
    func cropSlidesRatherThanShrinks() {
        let side = 0.25

        for centre in [CGPoint(x: 0.01, y: 0.02), CGPoint(x: 0.99, y: 0.98)] {
            let roi = BallROIPredictor.regionOfInterest(
                around: centre, sideFraction: side, aspect: aspect
            )

            // Size preserved, so magnification — and detection behaviour — is the same
            // wherever in the frame the ball happens to be.
            #expect(abs(roi.width - side) < 1e-9)
            #expect(abs(roi.height - side * aspect) < 1e-9)

            #expect(roi.minX >= -1e-9)
            #expect(roi.minY >= -1e-9)
            #expect(roi.maxX <= 1 + 1e-9)
            #expect(roi.maxY <= 1 + 1e-9)
        }
    }

    @Test("An oversized crop is capped but stays square")
    func oversizedCropStaysSquare() {
        let roi = BallROIPredictor.regionOfInterest(
            around: CGPoint(x: 0.5, y: 0.5), sideFraction: 0.9, aspect: aspect
        )

        #expect(roi.height <= 1 + 1e-9)
        #expect(roi.width <= 1 + 1e-9)
        #expect(abs((roi.width * 1920) - (roi.height * 1080)) < 1e-6)
    }

    @Test("The search window grows with consecutive misses, then stops")
    func windowGrowsWithMisses() {
        let config = BallROIPredictor.Config()

        let fresh = BallROIPredictor.sideFraction(consecutiveMisses: 0, config: config)
        let stale = BallROIPredictor.sideFraction(consecutiveMisses: 3, config: config)

        #expect(fresh == config.baseSideFraction)
        #expect(stale > fresh)
        #expect(BallROIPredictor.sideFraction(consecutiveMisses: 99, config: config)
                == config.maxSideFraction)
    }

    @Test("ROI-relative results map back to full-frame coordinates")
    func mapsResultsBackToFullFrame() {
        let roi = CGRect(x: 0.25, y: 0.40, width: 0.25, height: 0.44)

        // Dead centre of the crop must land at the centre of the crop in the full frame.
        let centred = BallROIPredictor.mapToFullFrame(
            roiRelative: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), roi: roi
        )
        #expect(abs(centred.midX - roi.midX) < 1e-9)
        #expect(abs(centred.midY - roi.midY) < 1e-9)

        // A box filling the crop must come back as the crop itself.
        let full = BallROIPredictor.mapToFullFrame(
            roiRelative: CGRect(x: 0, y: 0, width: 1, height: 1), roi: roi
        )
        #expect(abs(full.minX - roi.minX) < 1e-9)
        #expect(abs(full.minY - roi.minY) < 1e-9)
        #expect(abs(full.width - roi.width) < 1e-9)
        #expect(abs(full.height - roi.height) < 1e-9)
    }

    @Test("A ball detected in the crop keeps its real size after mapping")
    func mappingPreservesApparentSize() {
        // The ball fills more of the crop than it does of the frame — that magnification
        // is the entire point — but mapping back must restore its true frame-relative size.
        let roi = BallROIPredictor.regionOfInterest(
            around: CGPoint(x: 0.5, y: 0.5), sideFraction: 0.25, aspect: 16.0 / 9.0
        )
        // 9.6% of the crop's width.
        let inCrop = CGRect(x: 0.45, y: 0.45, width: 0.096, height: 0.096)

        let mapped = BallROIPredictor.mapToFullFrame(roiRelative: inCrop, roi: roi)

        // 0.096 x 0.25 = 0.024 of the frame — the ~46px ball in a 1920 frame.
        #expect(abs(mapped.width - 0.024) < 1e-6)
    }

    @Test("Prediction follows the ballistic arc when the fit is good")
    func predictsAlongArc() throws {
        let arc = ballisticArc(
            startFrame: 0, frames: 20,
            fromX: 0.2, fromY: 0.3, peakY: 0.8, landX: 0.7
        )
        let fit = try #require(fitMotionWeighted(arc))

        let predicted = try #require(
            BallROIPredictor.predictedCentre(history: arc, fit: fit, atFrame: 21)
        )
        let truth = predictPosition(fit: fit, t: 21)

        #expect(abs(predicted.x - truth.x) < 1e-6)
        #expect(abs(predicted.y - truth.y) < 1e-6)
    }

    @Test("Prediction falls back to linear motion without a usable fit")
    func fallsBackToLinearMotion() throws {
        let history = [
            BallObservation(frameID: 10, center: CGPoint(x: 0.40, y: 0.50), radius: 0.02, confidence: 0.9),
            BallObservation(frameID: 11, center: CGPoint(x: 0.44, y: 0.54), radius: 0.02, confidence: 0.9)
        ]

        let predicted = try #require(
            BallROIPredictor.predictedCentre(history: history, fit: nil, atFrame: 12)
        )

        #expect(abs(predicted.x - 0.48) < 1e-9)
        #expect(abs(predicted.y - 0.58) < 1e-9)
    }

    @Test("No history means no prediction, so the detector sweeps")
    func noHistoryNoPrediction() {
        #expect(BallROIPredictor.predictedCentre(history: [], fit: nil, atFrame: 0) == nil)
    }

    @Test("Detection stats separate crop hits from full-frame hits")
    func statsSeparateModes() {
        var stats = BallDetectionStats()

        stats.record(hit: true, cropped: true, confidence: 0.8)
        stats.record(hit: false, cropped: true, confidence: 0)
        stats.record(hit: true, cropped: false, confidence: 0.6)

        #expect(stats.framesProcessed == 3)
        #expect(stats.croppedAttempts == 2)
        #expect(stats.croppedHits == 1)
        #expect(stats.croppedHitRate == 0.5)
        #expect(stats.fullFrameHitRate == 1.0)
        #expect(abs(stats.meanConfidence - 0.7) < 1e-9)
        #expect(abs(stats.overallHitRate - (2.0 / 3.0)) < 1e-9)
    }
}

// MARK: - Seek time base

struct PresentationTimeTests {

    private let rim = HoopGeometry(
        center: CGPoint(x: 0.5, y: 0.70),
        verticalRadius: 0.012,
        horizontalRadius: 0.045
    )

    /// Stamp an arc with wall-clock times, optionally irregular ones.
    private func timed(
        _ observations: [BallObservation],
        secondsPerFrame: (Int) -> Double
    ) -> [BallObservation] {
        var elapsed = 0.0
        return observations.map { observation in
            let stamped = BallObservation(
                frameID: observation.frameID,
                center: observation.center,
                radius: observation.radius,
                confidence: observation.confidence,
                timeSeconds: elapsed
            )
            elapsed += secondsPerFrame(observation.frameID)
            return stamped
        }
    }

    private func resolve(_ observations: [BallObservation]) -> ShotAttempt? {
        var detector = ShotDetector()
        var events: [ShotEvent] = []
        for observation in observations {
            events.append(contentsOf: detector.process(observation: observation, rim: rim))
        }
        return events.compactMap {
            if case .attemptResolved(let attempt) = $0 { return attempt }
            return nil
        }.first
    }

    @Test("A resolved shot carries a real timestamp to seek to")
    func attemptCarriesSeekTime() throws {
        let arc = timed(shotArc(crossingX: 0.5)) { _ in 1.0 / 30.0 }

        let attempt = try #require(resolve(arc))
        #expect(attempt.result == .made)

        let key = try #require(attempt.keyTime)
        let start = try #require(attempt.startTime)
        let end = try #require(attempt.endTime)

        #expect(key > start)
        #expect(key <= end + 1e-9)
    }

    @Test("The crossing time is interpolated, not snapped to a frame")
    func crossingTimeIsInterpolated() throws {
        let fps = 30.0
        let arc = timed(shotArc(crossingX: 0.5)) { _ in 1.0 / fps }

        let attempt = try #require(resolve(arc))
        let crossing = try #require(attempt.scoringCrossing)
        let time = try #require(crossing.timeSeconds)

        // Lands between two frame boundaries rather than on one.
        let framePosition = time * fps
        #expect(abs(framePosition - framePosition.rounded()) > 1e-6)
    }

    @Test("Variable frame rate breaks index-derived time but not the real timestamp")
    func variableFrameRateNeedsRealTimestamps() throws {
        // Every third frame takes twice as long — an ordinary adaptive-frame-rate clip.
        let arc = timed(shotArc(crossingX: 0.5)) { frame in
            frame % 3 == 0 ? 2.0 / 30.0 : 1.0 / 30.0
        }

        let attempt = try #require(resolve(arc))
        let crossing = try #require(attempt.scoringCrossing)
        let actual = try #require(crossing.timeSeconds)

        // What you would get assuming a constant 30fps.
        let assumed = crossing.frame / 30.0

        // They disagree, and the gap grows with clip length — which is exactly why the
        // timestamp is carried rather than derived.
        #expect(abs(actual - assumed) > 0.05)

        // The real timestamp stays consistent with the frames either side of it.
        let before = arc.last(where: { Double($0.frameID) <= crossing.frame })
        let after = arc.first(where: { Double($0.frameID) >= crossing.frame })
        #expect(actual >= (before?.timeSeconds ?? 0) - 1e-9)
        #expect(actual <= (after?.timeSeconds ?? .infinity) + 1e-9)
    }

    @Test("Shot detection is unaffected by irregular frame timing")
    func detectionUsesFrameIndexNotWallClock() throws {
        // The fit runs on frame index, so the same arc must resolve identically whether
        // the frames were evenly spaced or not.
        let steady = timed(shotArc(crossingX: 0.5)) { _ in 1.0 / 30.0 }
        let jittery = timed(shotArc(crossingX: 0.5)) { frame in
            frame % 3 == 0 ? 2.0 / 30.0 : 1.0 / 30.0
        }

        let a = try #require(resolve(steady))
        let b = try #require(resolve(jittery))

        #expect(a.result == b.result)
        #expect(a.crossings.count == b.crossings.count)
        #expect(abs(a.scoringCrossing!.normalisedOffset - b.scoringCrossing!.normalisedOffset) < 1e-9)
    }

    @Test("An attempt keeps the rim it was judged against")
    func attemptCapturesItsRim() throws {
        let attempt = try #require(resolve(timed(shotArc(crossingX: 0.5)) { _ in 1.0 / 30.0 }))
        // A card draws this rim, so it has to be the one that produced the verdict.
        #expect(attempt.rim == rim)
    }

    @Test("Without timestamps a shot still resolves, just isn't seekable")
    func timestampsAreOptional() throws {
        let attempt = try #require(resolve(shotArc(crossingX: 0.5)))
        #expect(attempt.result == .made)
        #expect(attempt.keyTime == nil)
    }
}

// MARK: - Replay layout

struct VideoLayoutTests {

    @Test("A quarter-turn swaps the video's width and height")
    func orientationSwapsDimensions() {
        let portrait = CGSize(width: 1080, height: 1920)

        // Vision analyses the oriented image, so the overlay must use the same shape.
        #expect(VideoLayout.orientedSize(portrait, orientation: .up) == portrait)
        #expect(VideoLayout.orientedSize(portrait, orientation: .right)
                == CGSize(width: 1920, height: 1080))
        #expect(VideoLayout.orientedSize(portrait, orientation: .left)
                == CGSize(width: 1920, height: 1080))
        #expect(VideoLayout.orientedSize(portrait, orientation: .down) == portrait)
    }

    @Test("A wide video letterboxes vertically inside a squarer container")
    func letterboxesVertically() {
        let rect = VideoLayout.contentRect(
            for: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 400, height: 400)
        )

        #expect(rect.width == 400)
        #expect(abs(rect.height - 225) < 1e-9)
        // Centred, with equal bars above and below.
        #expect(abs(rect.minY - 87.5) < 1e-9)
        #expect(rect.minX == 0)
    }

    @Test("A tall video pillarboxes horizontally")
    func pillarboxesHorizontally() {
        let rect = VideoLayout.contentRect(
            for: CGSize(width: 1080, height: 1920),
            in: CGSize(width: 400, height: 400)
        )

        #expect(rect.height == 400)
        #expect(abs(rect.width - 225) < 1e-9)
        #expect(abs(rect.minX - 87.5) < 1e-9)
    }

    @Test("Normalized points land inside the picture, not the container")
    func mapsIntoContentRect() {
        let container = CGSize(width: 400, height: 400)
        let content = VideoLayout.contentRect(for: CGSize(width: 1920, height: 1080), in: container)

        // Centre of the frame is the centre of the picture.
        let centre = VideoLayout.point(normalized: CGPoint(x: 0.5, y: 0.5), in: content)
        #expect(abs(centre.x - 200) < 1e-9)
        #expect(abs(centre.y - 200) < 1e-9)

        // Top of the frame (y = 1 in Vision) is the top of the PICTURE, inside the
        // letterbox — mapping against the container would put it at the view's top edge.
        let top = VideoLayout.point(normalized: CGPoint(x: 0.5, y: 1.0), in: content)
        #expect(abs(top.y - content.minY) < 1e-9)
        #expect(top.y > 0)

        let bottom = VideoLayout.point(normalized: CGPoint(x: 0.5, y: 0.0), in: content)
        #expect(abs(bottom.y - content.maxY) < 1e-9)
        #expect(bottom.y < container.height)
    }

    @Test("Vision's y-up flips to the view's y-down")
    func flipsVerticalAxis() {
        let content = CGRect(x: 0, y: 0, width: 100, height: 100)

        let high = VideoLayout.point(normalized: CGPoint(x: 0.5, y: 0.9), in: content)
        let low = VideoLayout.point(normalized: CGPoint(x: 0.5, y: 0.1), in: content)

        // High in the frame must draw nearer the top of the view.
        #expect(high.y < low.y)
    }

    @Test("A degenerate container doesn't produce a broken rect")
    func handlesZeroSizes() {
        let rect = VideoLayout.contentRect(for: .zero, in: CGSize(width: 100, height: 100))
        #expect(rect.width == 100)
        #expect(rect.height == 100)
    }
}

struct BallInterpolationTests {

    private func observation(_ frame: Int, _ x: Double, _ y: Double, _ t: Double) -> BallObservation {
        BallObservation(
            frameID: frame, center: CGPoint(x: x, y: y),
            radius: 0.02, confidence: 0.9, timeSeconds: t
        )
    }

    @Test("The marker interpolates between sightings rather than hopping")
    func interpolatesBetweenSightings() throws {
        let trajectory = [
            observation(0, 0.20, 0.40, 1.0),
            observation(1, 0.30, 0.60, 2.0)
        ]

        let midway = try #require(interpolatedBallPosition(trajectory: trajectory, atTime: 1.5))
        #expect(abs(midway.x - 0.25) < 1e-9)
        #expect(abs(midway.y - 0.50) < 1e-9)
    }

    @Test("Interpolation uses real time, not frame index")
    func usesRealTimeSpacing() throws {
        // The second gap takes three times as long as the first — a variable-frame-rate
        // clip. Interpolating by index would put the marker in the wrong place.
        let trajectory = [
            observation(0, 0.0, 0.5, 0.0),
            observation(1, 0.1, 0.5, 1.0),
            observation(2, 0.4, 0.5, 4.0)
        ]

        let at = try #require(interpolatedBallPosition(trajectory: trajectory, atTime: 2.5))
        // Halfway through the second gap in TIME is x = 0.25.
        #expect(abs(at.x - 0.25) < 1e-9)
    }

    @Test("Times outside the trajectory clamp to its ends")
    func clampsOutsideRange() throws {
        let trajectory = [
            observation(0, 0.2, 0.4, 1.0),
            observation(1, 0.3, 0.6, 2.0)
        ]

        let before = try #require(interpolatedBallPosition(trajectory: trajectory, atTime: 0.0))
        let after = try #require(interpolatedBallPosition(trajectory: trajectory, atTime: 99.0))

        #expect(before == CGPoint(x: 0.2, y: 0.4))
        #expect(after == CGPoint(x: 0.3, y: 0.6))
    }

    @Test("Untimed sightings yield no marker")
    func requiresTimestamps() {
        let untimed = [
            BallObservation(frameID: 0, center: CGPoint(x: 0.2, y: 0.4), radius: 0.02, confidence: 0.9)
        ]
        #expect(interpolatedBallPosition(trajectory: untimed, atTime: 1.0) == nil)
        #expect(interpolatedBallPosition(trajectory: [], atTime: 1.0) == nil)
    }
}

// MARK: - User corrections

@MainActor
struct CorrectionTests {

    private func attempt(
        _ result: ShotAttempt.Result,
        verdict: ShotAttempt.UserVerdict? = nil
    ) -> ShotAttempt {
        ShotAttempt(
            id: UUID(), startFrame: 0, endFrame: 10, result: result,
            trajectory: [], crossings: [], rimContacts: 0,
            apexY: nil, wasDetectedLate: false, rim: nil, userVerdict: verdict
        )
    }

    @Test("A ruling overrides the detector without erasing it")
    func rulingPreservesDetectorCall() {
        let shot = attempt(.missed, verdict: .made)

        // Both survive: the detector's call is what's being measured, the user's is
        // the ground truth it's measured against.
        #expect(shot.result == .missed)
        #expect(shot.effectiveResult == .made)
        #expect(shot.isCorrected)
    }

    @Test("Agreeing with the detector is not a correction")
    func agreementIsNotCorrection() {
        let shot = attempt(.made, verdict: .made)
        #expect(shot.isCorrected == false)
        #expect(shot.effectiveResult == .made)
    }

    @Test("Correcting an old shot updates the score retroactively")
    func correctionsApplyRetroactively() {
        let state = GameState()
        let made = attempt(.made)
        let missed = attempt(.missed)

        state.handle(.attemptResolved(made))
        state.handle(.attemptResolved(missed))

        #expect(state.stats.attempts == 2)
        #expect(state.stats.makes == 1)

        // Stats are derived, not accumulated, so a late ruling is reflected at once —
        // counters incremented as events arrived could not do this.
        state.setVerdict(.made, for: missed.id)

        #expect(state.stats.makes == 2)
        #expect(state.stats.points == 4)
        #expect(abs(state.stats.fieldGoalPercentage - 100) < 1e-9)
    }

    @Test("A shot ruled not-a-shot leaves the totals entirely")
    func falsePositiveLeavesTotals() {
        let state = GameState()
        let real = attempt(.made)
        let bogus = attempt(.made)

        state.handle(.attemptResolved(real))
        state.handle(.attemptResolved(bogus))
        #expect(state.stats.attempts == 2)

        state.setVerdict(.notAShot, for: bogus.id)

        // Not a miss — it never happened, so it can't count against the percentage.
        #expect(state.stats.attempts == 1)
        #expect(state.stats.makes == 1)
        #expect(abs(state.stats.fieldGoalPercentage - 100) < 1e-9)
    }

    @Test("Ruling on an abandoned attempt promotes it into the totals")
    func rulingResolvesAbandoned() {
        let state = GameState()
        let lost = attempt(.abandoned)

        state.handle(.attemptResolved(lost))
        #expect(state.stats.attempts == 0)
        #expect(state.abandonedAttempts.count == 1)

        state.setVerdict(.made, for: lost.id)

        #expect(state.stats.attempts == 1)
        #expect(state.stats.makes == 1)
    }

    @Test("Clearing a ruling hands the shot back to the detector")
    func clearingRulingRestoresDetectorCall() {
        let state = GameState()
        let shot = attempt(.missed)
        state.handle(.attemptResolved(shot))

        state.setVerdict(.made, for: shot.id)
        #expect(state.stats.makes == 1)

        state.setVerdict(nil, for: shot.id)

        #expect(state.stats.makes == 0)
        #expect(state.stats.attempts == 1)
        #expect(state.attempt(withID: shot.id)?.isCorrected == false)
    }

    @Test("Accuracy counts only shots the user has ruled on")
    func accuracyIgnoresUnreviewed() {
        let state = GameState()
        let agreed = attempt(.made)
        let flipped = attempt(.made)
        let bogus = attempt(.missed)
        let untouched = attempt(.missed)

        for shot in [agreed, flipped, bogus, untouched] {
            state.handle(.attemptResolved(shot))
        }

        state.setVerdict(.made, for: agreed.id)
        state.setVerdict(.missed, for: flipped.id)
        state.setVerdict(.notAShot, for: bogus.id)

        let accuracy = state.accuracy
        #expect(accuracy.reviewed == 3)
        #expect(accuracy.agreed == 1)
        #expect(accuracy.wrongCalls == 1)
        #expect(accuracy.falsePositives == 1)
        #expect(abs(accuracy.agreementRate - (100.0 / 3.0)) < 0.01)
    }

    @Test("Accuracy is zero-safe before anything is reviewed")
    func accuracyBeforeReview() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(.made)))

        #expect(state.accuracy.reviewed == 0)
        #expect(state.accuracy.agreementRate == 0)
    }

    @Test("Ruling an unknown id changes nothing")
    func unknownIdIsIgnored() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(.made)))

        state.setVerdict(.missed, for: UUID())

        #expect(state.stats.attempts == 1)
        #expect(state.stats.makes == 1)
    }
}

// MARK: - Persistence

struct GroundTruthMatcherTests {

    private func attempt(at time: Double?, result: ShotAttempt.Result = .missed) -> ShotAttempt {
        let trajectory: [BallObservation] = time.map { t in
            [BallObservation(frameID: 0, center: CGPoint(x: 0.5, y: 0.5),
                             radius: 0.02, confidence: 0.9, timeSeconds: t)]
        } ?? []

        return ShotAttempt(
            id: UUID(), startFrame: 0, endFrame: 1, result: result,
            trajectory: trajectory, crossings: [], rimContacts: 0,
            apexY: nil, wasDetectedLate: false, rim: nil, userVerdict: nil
        )
    }

    @Test("Rulings survive re-analysis by matching on time, not id")
    func rulingsSurviveReanalysis() throws {
        let truth = [GroundTruthEntry(timeSeconds: 12.0, verdict: .made)]

        // A fresh run: brand new attempt id, very slightly different timing.
        let reanalysed = [attempt(at: 12.08, result: .missed)]
        let matched = GroundTruthMatcher.apply(truth, to: reanalysed)

        #expect(matched.first?.userVerdict == .made)
        #expect(matched.first?.effectiveResult == .made)
        #expect(matched.first?.isCorrected == true)
    }

    @Test("A ruling doesn't leak onto a different shot")
    func doesNotMatchDistantShots() {
        let truth = [GroundTruthEntry(timeSeconds: 12.0, verdict: .made)]
        let matched = GroundTruthMatcher.apply(truth, to: [attempt(at: 30.0)])

        #expect(matched.first?.userVerdict == nil)
    }

    @Test("Two nearby shots can't both claim one ruling")
    func rulingIsClaimedOnce() {
        let truth = [GroundTruthEntry(timeSeconds: 12.0, verdict: .made)]

        // Both fall inside the tolerance; only the nearer should take it.
        let matched = GroundTruthMatcher.apply(
            truth,
            to: [attempt(at: 12.9), attempt(at: 12.05)]
        )

        #expect(matched[0].userVerdict == nil)
        #expect(matched[1].userVerdict == .made)
    }

    @Test("Attempts with no timestamp are left alone")
    func untimedAttemptsSkipped() {
        let truth = [GroundTruthEntry(timeSeconds: 12.0, verdict: .made)]
        let matched = GroundTruthMatcher.apply(truth, to: [attempt(at: nil)])
        #expect(matched.first?.userVerdict == nil)
    }

    @Test("Recording a ruling replaces any earlier one at that moment")
    func recordingReplacesInPlace() {
        var truth: [GroundTruthEntry] = []

        truth = GroundTruthMatcher.record(verdict: .made, atTime: 12.0, into: truth)
        #expect(truth.count == 1)

        // Changing their mind about the same shot must not leave two entries behind.
        truth = GroundTruthMatcher.record(verdict: .missed, atTime: 12.1, into: truth)
        #expect(truth.count == 1)
        #expect(truth.first?.verdict == .missed)

        truth = GroundTruthMatcher.record(verdict: .made, atTime: 40.0, into: truth)
        #expect(truth.count == 2)
        // Kept in time order, so the file reads sensibly.
        #expect(truth[0].timeSeconds < truth[1].timeSeconds)
    }

    @Test("Clearing a ruling removes it from the record")
    func clearingRemovesEntry() {
        var truth = GroundTruthMatcher.record(verdict: .made, atTime: 12.0, into: [])
        truth = GroundTruthMatcher.record(verdict: nil, atTime: 12.0, into: truth)
        #expect(truth.isEmpty)
    }

    @Test("Scoring a run counts shots it failed to find at all")
    func scoringCountsMissedShots() {
        let truth = [
            GroundTruthEntry(timeSeconds: 10.0, verdict: .made),
            GroundTruthEntry(timeSeconds: 20.0, verdict: .made),
            GroundTruthEntry(timeSeconds: 30.0, verdict: .missed)
        ]

        // This run only found the first shot, and got it right.
        let score = GroundTruthMatcher.score(run: [attempt(at: 10.0, result: .made)], against: truth)

        #expect(score.reviewed == 1)
        #expect(score.agreed == 1)
        // Without this, a detector that quietly stopped finding shots would score 100%.
        #expect(score.missedShots == 2)
    }

    @Test("Scoring separates wrong calls from invented shots")
    func scoringSeparatesErrorKinds() {
        let truth = [
            GroundTruthEntry(timeSeconds: 10.0, verdict: .missed),
            GroundTruthEntry(timeSeconds: 20.0, verdict: .notAShot)
        ]

        let score = GroundTruthMatcher.score(
            run: [attempt(at: 10.0, result: .made), attempt(at: 20.0, result: .made)],
            against: truth
        )

        #expect(score.wrongCalls == 1)
        #expect(score.falsePositives == 1)
        #expect(score.agreed == 0)
    }
}

struct ShotStoreTests {

    private func makeStore() -> (ShotStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ShotStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ShotStore(root: root), root)
    }

    @Test("Ground truth round-trips through disk")
    func truthRoundTrips() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var document = GroundTruthDocument(assetIdentifier: "ABC/123")
        document.rim = HoopGeometry(
            center: CGPoint(x: 0.5, y: 0.7), verticalRadius: 0.012, horizontalRadius: 0.045
        )
        document.shots = [GroundTruthEntry(timeSeconds: 12.5, verdict: .made)]

        try store.saveTruth(document)
        let loaded = store.loadTruth(for: "ABC/123")

        // The identifier contains a slash — it must not have been read as a path.
        #expect(loaded.rim == document.rim)
        #expect(loaded.shots.count == 1)
        #expect(loaded.shots.first?.verdict == .made)
        #expect(abs((loaded.shots.first?.timeSeconds ?? 0) - 12.5) < 1e-9)
    }

    @Test("An unknown video loads as empty rather than failing")
    func missingTruthIsEmpty() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = store.loadTruth(for: "never-seen")
        #expect(loaded.shots.isEmpty)
        #expect(loaded.rim == nil)
    }

    @Test("Re-analysing replaces the run but keeps the corrections")
    func reanalysisKeepsCorrections() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "video-1"

        try store.saveTruth(GroundTruthDocument(
            assetIdentifier: id,
            shots: [GroundTruthEntry(timeSeconds: 12.0, verdict: .made)]
        ))

        func run(resultAt time: Double, result: ShotAttempt.Result) -> AnalysisRun {
            AnalysisRun(
                assetIdentifier: id,
                detectorConfig: ShotDetectorConfig(),
                attempts: [ShotAttempt(
                    id: UUID(), startFrame: 0, endFrame: 1, result: result,
                    trajectory: [BallObservation(
                        frameID: 0, center: CGPoint(x: 0.5, y: 0.5),
                        radius: 0.02, confidence: 0.9, timeSeconds: time
                    )],
                    crossings: [], rimContacts: 0, apexY: nil,
                    wasDetectedLate: false, rim: nil, userVerdict: nil
                )]
            )
        }

        try store.saveRun(run(resultAt: 12.0, result: .missed))
        let first = store.load(for: id)
        #expect(first.run?.attempts.first?.userVerdict == .made)

        // A second pass with different settings mints a new attempt id and shifts timing.
        try store.saveRun(run(resultAt: 12.15, result: .made))
        let second = store.load(for: id)

        // The ruling is still attached — which is the entire reason truth is stored
        // separately and keyed by time.
        #expect(second.run?.attempts.first?.userVerdict == .made)
        #expect(second.run?.attempts.first?.isCorrected == false)
        #expect(store.loadTruth(for: id).shots.count == 1)
    }

    @Test("A corrupt file is treated as absent, not fatal")
    func corruptFileIsIgnored() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.saveTruth(GroundTruthDocument(
            assetIdentifier: "v", shots: [GroundTruthEntry(timeSeconds: 1, verdict: .made)]
        ))

        // Simulate a partial write or a file from an incompatible build.
        let directory = root.appending(path: "v".addingPercentEncoding(
            withAllowedCharacters: .alphanumerics)!, directoryHint: .isDirectory)
        try Data("{ not json".utf8).write(to: directory.appending(path: "truth.json"))

        let loaded = store.loadTruth(for: "v")
        #expect(loaded.shots.isEmpty)
    }

    @Test("Deleting removes everything stored for a video")
    func deleteRemovesAll() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.saveTruth(GroundTruthDocument(
            assetIdentifier: "v", shots: [GroundTruthEntry(timeSeconds: 1, verdict: .made)]
        ))
        #expect(store.storedAssetIdentifiers().contains("v"))

        try store.delete(assetIdentifier: "v")

        #expect(store.loadTruth(for: "v").shots.isEmpty)
        #expect(store.storedAssetIdentifiers().contains("v") == false)
    }
}

// MARK: - Saved game library

@MainActor
struct SavedGameTests {

    private func makeStore() -> (ShotStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SavedGameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ShotStore(root: root), root)
    }

    private func attempt(
        at time: Double,
        result: ShotAttempt.Result,
        verdict: ShotAttempt.UserVerdict? = nil
    ) -> ShotAttempt {
        ShotAttempt(
            id: UUID(), startFrame: 0, endFrame: 1, result: result,
            trajectory: [BallObservation(
                frameID: 0, center: CGPoint(x: 0.5, y: 0.5),
                radius: 0.02, confidence: 0.9, timeSeconds: time
            )],
            crossings: [], rimContacts: 0, apexY: nil,
            wasDetectedLate: false, rim: nil, userVerdict: verdict
        )
    }

    @Test("Summaries describe a run without parsing it")
    func summaryFromAttempts() {
        let summary = SavedGameSummary(
            assetIdentifier: "v",
            attempts: [
                attempt(at: 1, result: .made),
                attempt(at: 2, result: .missed),
                attempt(at: 3, result: .missed, verdict: .made),
                attempt(at: 4, result: .made, verdict: .notAShot)
            ]
        )

        // The false positive leaves the totals; the corrected miss counts as a make.
        #expect(summary.attempts == 3)
        #expect(summary.makes == 2)
        #expect(summary.reviewed == 2)
        #expect(summary.agreed == 0)
    }

    @Test("The library lists saved games newest first")
    func libraryOrdersByDate() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        try store.saveSummary(SavedGameSummary(
            assetIdentifier: "old", analysedAt: older,
            attempts: 5, makes: 2, reviewed: 0, agreed: 0
        ))
        try store.saveSummary(SavedGameSummary(
            assetIdentifier: "new", analysedAt: newer,
            attempts: 3, makes: 3, reviewed: 0, agreed: 0
        ))

        let listed = store.summaries()
        #expect(listed.map(\.assetIdentifier) == ["new", "old"])
    }

    @Test("A saved run reopens with its rulings intact")
    func loadingRestoresRulings() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "video"
        let run = AnalysisRun(
            assetIdentifier: id,
            detectorConfig: ShotDetectorConfig(),
            attempts: [
                attempt(at: 10, result: .missed),
                attempt(at: 20, result: .made),
                attempt(at: 30, result: .abandoned)
            ]
        )
        try store.saveRun(run)
        try store.saveTruth(GroundTruthDocument(
            assetIdentifier: id,
            shots: [GroundTruthEntry(timeSeconds: 10.0, verdict: .made)]
        ))

        let loaded = store.load(for: id)
        let state = GameState()
        state.load(run: try #require(loaded.run), truth: loaded.truth)

        // Resolved and abandoned attempts are sorted the way live events would have,
        // so every view that works on a live game works on a reopened one.
        #expect(state.shotTimeline.count == 2)
        #expect(state.abandonedAttempts.count == 1)

        // The stored ruling flipped the first shot.
        #expect(state.stats.attempts == 2)
        #expect(state.stats.makes == 2)
        #expect(state.accuracy.reviewed == 1)
        #expect(state.accuracy.wrongCalls == 1)
    }

    @Test("Correcting a reopened game writes back and survives another reopen")
    func correctingReopenedGamePersists() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "video"
        try store.saveRun(AnalysisRun(
            assetIdentifier: id,
            detectorConfig: ShotDetectorConfig(),
            attempts: [attempt(at: 42, result: .made)]
        ))

        // Reopen, correct.
        let first = store.load(for: id)
        let state = GameState()
        state.load(run: try #require(first.run), truth: first.truth)

        let shot = try #require(state.shotTimeline.first)
        state.setVerdict(.missed, for: shot.id)

        var document = first.truth
        document.shots = GroundTruthMatcher.record(
            verdict: .missed, atTime: 42, into: document.shots
        )
        try store.saveTruth(document)

        // Reopen again — a fresh GameState, ids rematched by time.
        let second = store.load(for: id)
        let reopened = GameState()
        reopened.load(run: try #require(second.run), truth: second.truth)

        #expect(reopened.stats.makes == 0)
        #expect(reopened.stats.attempts == 1)
        #expect(reopened.shotTimeline.first?.userVerdict == .missed)
    }

    @Test("An empty library lists nothing rather than failing")
    func emptyLibrary() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.summaries().isEmpty)
    }
}
