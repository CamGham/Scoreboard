//
//  ShotDetector.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation

// MARK: - Results

/// Where and when the ball passed down through the rim plane.
struct RimCrossing: Codable, Equatable {
    /// Absolute frame, carrying sub-frame precision from interpolation.
    let frame: Double

    /// Horizontal position of the ball centre at the crossing.
    let x: Double

    /// Offset from the rim centre in units of rim radius.
    /// `0` is dead centre, `±1` is the ring itself, beyond `±1` missed the ring entirely.
    let normalisedOffset: Double

    /// True when the ball centre passed through the opening with room for the ball's width.
    let isClean: Bool

    /// When the crossing happened, in seconds from the start of the media —
    /// interpolated between the two straddling frames, same as the position.
    /// This is what a replay or a still frame seeks to.
    let timeSeconds: Double?
}

struct ShotAttempt: Codable, Identifiable, Equatable {

    /// What the user says actually happened, when they disagree with the detector or
    /// resolve something it couldn't.
    ///
    /// Kept *alongside* `result` rather than overwriting it. Both are needed: the
    /// detector's call is what you are measuring, the user's is the ground truth you are
    /// measuring it against. Overwriting would destroy the comparison the moment it
    /// became useful.
    enum UserVerdict: String, Codable, CaseIterable {
        case made
        case missed
        /// Not a shot at all — a pass, a rebound, a detector artefact.
        case notAShot

        var label: String {
            switch self {
            case .made: return "Made"
            case .missed: return "Missed"
            case .notAShot: return "Not a shot"
            }
        }

        var symbol: String {
            switch self {
            case .made: return "checkmark.circle.fill"
            case .missed: return "xmark.circle.fill"
            case .notAShot: return "nosign"
            }
        }
    }

    enum Result: String, Codable {
        case inProgress
        case made
        case missed
        /// Opened but never resolved — ball lost, or the clip ended mid-flight.
        case abandoned
    }

    let id: UUID
    var startFrame: Int
    var endFrame: Int?
    var result: Result

    /// Every ball sighting from the start of the attempt onward.
    var trajectory: [BallObservation]

    /// Downward crossings of the rim plane, in order. A clean shot has one; a shot that
    /// rattles in off the front rim has several.
    var crossings: [RimCrossing]

    /// Times the ball visibly broke away from its parabola near the rim — rim or
    /// backboard contact.
    var rimContacts: Int

    /// Highest point the ball reached, in normalized image space.
    var apexY: Double?

    /// True when the attempt was picked up on its way down rather than at release, so
    /// the early trajectory is missing.
    var wasDetectedLate: Bool

    /// The rim this attempt was judged against, captured at the time so a card or replay
    /// draws the geometry that actually produced the verdict.
    var rim: HoopGeometry?

    /// The user's ruling, if they have given one.
    var userVerdict: UserVerdict?

    /// The verdict that counts — the user's where they gave one, else the detector's.
    var effectiveResult: Result {
        switch userVerdict {
        case .made: return .made
        case .missed: return .missed
        case .notAShot, .none: return result
        }
    }

    /// Whether this belongs in the field-goal totals. Something ruled `notAShot`, still
    /// in flight, or abandoned without a ruling does not.
    var isCountedAttempt: Bool {
        guard userVerdict != .notAShot else { return false }
        return effectiveResult == .made || effectiveResult == .missed
    }

    var isCountedMake: Bool {
        isCountedAttempt && effectiveResult == .made
    }

    /// True when the user's ruling contradicts the detector.
    var isCorrected: Bool {
        guard let userVerdict else { return false }
        switch userVerdict {
        case .made: return result != .made
        case .missed: return result != .missed
        case .notAShot: return true
        }
    }

    /// Media time of the first and last sighting, in seconds.
    var startTime: Double? { trajectory.first?.timeSeconds }
    var endTime: Double? { trajectory.last?.timeSeconds }

    /// The single most representative moment of the attempt: the rim crossing if there
    /// was one, otherwise the end. This is the frame worth showing on a card.
    var keyTime: Double? {
        crossings.first(where: { $0.isClean })?.timeSeconds
            ?? crossings.last?.timeSeconds
            ?? endTime
    }

    /// The crossing that decided a make.
    var scoringCrossing: RimCrossing? {
        crossings.first(where: { $0.isClean })
    }

    /// How close to the rim edge the deciding crossing was. Near 1.0 means the verdict
    /// rested on a fraction of a rim radius and is worth a human look.
    var isCloseCall: Bool {
        guard let deciding = crossings.min(by: { abs($0.normalisedOffset) < abs($1.normalisedOffset) }) else {
            return false
        }
        return abs(abs(deciding.normalisedOffset) - 1.0) < 0.15
    }

    static func == (lhs: ShotAttempt, rhs: ShotAttempt) -> Bool {
        lhs.id == rhs.id
            && lhs.result == rhs.result
            && lhs.endFrame == rhs.endFrame
            && lhs.userVerdict == rhs.userVerdict
    }
}

enum ShotEvent {
    case attemptStarted(ShotAttempt)
    case rimContact(id: UUID)
    case attemptResolved(ShotAttempt)
}

// MARK: - Tuning

struct ShotDetectorConfig: Codable, Equatable {
    /// Observations kept for fitting the live arc.
    var fitWindow: Int = 24

    /// How far ahead the fit is trusted to predict a rim crossing, in frames.
    var predictionHorizon: Double = 45

    /// The apex must clear the top of the rim by this many ball radii before a rising
    /// ball counts as a shot rather than a pass or a high dribble.
    var launchApexMarginInRadii: Double = 1.0

    /// Vertical extent of the "approaching the rim" zone above the rim plane,
    /// in ball radii. Used to catch shots whose release we missed.
    var rimZoneHeightInRadii: Double = 10.0

    /// Horizontal half-extent of the rim zone, in rim radii.
    var rimZoneWidthInRimRadii: Double = 2.0 // tweak here if needed

    /// How much of the ball must be inside the ring at the crossing.
    /// `1.0` demands the whole ball clear the edge, `0.0` only asks that the ball's
    /// centre be inside. The default leaves room for detector jitter on both the ball
    /// box and the rim box.
    var makeBallClearance: Double = 0.5 // tweak here if needed

    /// Once the ball is this many ball radii below the rim plane, it can no longer
    /// come back, so a miss can be called.
    var missConfirmDepthInRadii: Double = 4.0

    /// Consecutive frames below that depth before the miss is committed.
    var missConfirmFrames: Int = 3

    /// New attempts are suppressed for this many frames after one resolves, so a ball
    /// bouncing off the floor under the hoop can't open a second attempt.
    var cooldownFrames: Int = 15

    /// An attempt open this long without resolving is abandoned.
    var attemptTimeoutFrames: Int = 180

    /// A gap in ball sightings longer than this abandons the attempt.
    var maxTrackingGapFrames: Int = 30

    /// A crossing only counts when the ball is genuinely falling freely. Guards against
    /// a rebound plucked above the rim and carried down being scored as a basket.
    var requireBallisticCrossing: Bool = true

    init() {}

    // Decoded leniently: any key absent falls back to today's default.
    //
    // Swift's synthesised decoder demands every key, so adding a setting would make
    // every previously saved run unreadable — and a stored run is the baseline you are
    // trying to compare against. Property defaults are not used as fallbacks unless the
    // decoding is written out like this.
    private enum CodingKeys: String, CodingKey {
        case fitWindow, predictionHorizon, launchApexMarginInRadii
        case rimZoneHeightInRadii, rimZoneWidthInRimRadii, makeBallClearance
        case missConfirmDepthInRadii, missConfirmFrames, cooldownFrames
        case attemptTimeoutFrames, maxTrackingGapFrames, requireBallisticCrossing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShotDetectorConfig()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }

        fitWindow = value(.fitWindow, defaults.fitWindow)
        predictionHorizon = value(.predictionHorizon, defaults.predictionHorizon)
        launchApexMarginInRadii = value(.launchApexMarginInRadii, defaults.launchApexMarginInRadii)
        rimZoneHeightInRadii = value(.rimZoneHeightInRadii, defaults.rimZoneHeightInRadii)
        rimZoneWidthInRimRadii = value(.rimZoneWidthInRimRadii, defaults.rimZoneWidthInRimRadii)
        makeBallClearance = value(.makeBallClearance, defaults.makeBallClearance)
        missConfirmDepthInRadii = value(.missConfirmDepthInRadii, defaults.missConfirmDepthInRadii)
        missConfirmFrames = value(.missConfirmFrames, defaults.missConfirmFrames)
        cooldownFrames = value(.cooldownFrames, defaults.cooldownFrames)
        attemptTimeoutFrames = value(.attemptTimeoutFrames, defaults.attemptTimeoutFrames)
        maxTrackingGapFrames = value(.maxTrackingGapFrames, defaults.maxTrackingGapFrames)
        requireBallisticCrossing = value(.requireBallisticCrossing, defaults.requireBallisticCrossing)
    }
}

// MARK: - Detector

/// Decides when a shot is attempted and whether it went in.
///
/// The verdict is deterministic and comes from the *observed* ball positions: find the
/// two consecutive sightings that straddle the rim plane while the ball is descending,
/// interpolate the crossing point, and ask whether it lies inside the ring. The fitted
/// parabola is used only to anticipate a shot and to drive the live overlay — never to
/// decide the outcome.
///
/// Known limitation: a single camera cannot separate depth. A ball passing directly in
/// front of or behind the rim at the same image position as a make is geometrically
/// indistinguishable from one. Shots flagged by `isCloseCall` are the ones most likely
/// to be affected.
struct ShotDetector {

    private(set) var config: ShotDetectorConfig

    /// Rolling window of recent ball sightings, oldest first.
    private(set) var history: [BallObservation] = []

    private(set) var currentAttempt: ShotAttempt?
    private(set) var state: BallState = .idle

    /// Live arc fit, for the overlay.
    private(set) var currentFit: MotionFit?

    /// Predicted absolute frame at which the ball reaches the rim plane.
    private(set) var predictedCrossingFrame: Double?

    private var cooldownUntilFrame: Int?
    private var framesBelowRim: Int = 0

    init(config: ShotDetectorConfig = ShotDetectorConfig()) {
        self.config = config
    }

    mutating func reset() {
        history.removeAll()
        currentAttempt = nil
        state = .idle
        currentFit = nil
        predictedCrossingFrame = nil
        cooldownUntilFrame = nil
        framesBelowRim = 0
    }

    // MARK: Main entry point

    /// Feed one ball sighting. Returns whatever the pipeline should react to.
    ///
    /// Observations must arrive in non-decreasing frame order; a repeat of the newest
    /// frame is ignored so a detect-and-track pass over the same frame can't
    /// double-count the ball.
    @discardableResult
    mutating func process(
        observation: BallObservation,
        rim: HoopGeometry?
    ) -> [ShotEvent] {

        if let newest = history.last {
            guard observation.frameID > newest.frameID else { return [] }
        }

        let previous = history.last
        history.append(observation)
        if history.count > config.fitWindow {
            history.removeFirst(history.count - config.fitWindow)
        }

        currentFit = fitMotionWeighted(history)

        guard let rim else {
            // Without a rim there is no scoring plane, so keep collecting but decide nothing.
            predictedCrossingFrame = nil
            return []
        }

        var events: [ShotEvent] = []

        if currentAttempt != nil {
            events.append(contentsOf: advanceAttempt(from: previous, to: observation, rim: rim))
        } else {
            events.append(contentsOf: lookForAttemptStart(observation: observation, rim: rim))

            // A shot opened by rim-zone entry may already be straddling the plane on
            // this very frame; evaluate it now rather than losing the crossing.
            if currentAttempt != nil, let previous {
                events.append(contentsOf: advanceAttempt(from: previous, to: observation, rim: rim))
            }
        }

        updatePrediction(rim: rim, now: observation.frameID)

        return events
    }

    /// Call when the ball has not been seen for a while, or the source ended, so an
    /// open attempt doesn't linger forever.
    @discardableResult
    mutating func flush(atFrame frame: Int) -> [ShotEvent] {
        guard currentAttempt != nil else { return [] }
        return [resolve(result: .abandoned, endFrame: frame)]
    }

    // MARK: Attempt start

    private mutating func lookForAttemptStart(
        observation: BallObservation,
        rim: HoopGeometry
    ) -> [ShotEvent] {

        if let cooldownUntilFrame, observation.frameID < cooldownUntilFrame {
            return []
        }

        let ballRadius = smoothedRadius(history: history)
        guard ballRadius > 0 else { return [] }

        if detectedLaunch(observation: observation, rim: rim, ballRadius: ballRadius) {
            return [openAttempt(rim: rim, late: false)]
        }

        if enteredRimZoneDescending(observation: observation, rim: rim, ballRadius: ballRadius) {
            return [openAttempt(rim: rim, late: true)]
        }

        return []
    }

    /// A rising, freely-falling ball whose arc peaks above the rim and is predicted to
    /// come back down through the rim plane near the hoop.
    private func detectedLaunch(
        observation: BallObservation,
        rim: HoopGeometry,
        ballRadius: Double
    ) -> Bool {

        guard let fit = currentFit, fit.isBallistic else { return false }
        guard fit.sampleCount >= 5 else { return false }

        let now = Double(observation.frameID)
        let velocity = predictVelocity(fit: fit, t: now)

        // Must still be on the way up.
        guard velocity.vy > 0 else { return false }

        // Must peak clear of the rim. This is what separates a shot from a dribble or a
        // chest pass, both of which top out well below the ring.
        guard let apex = predictApex(fit: fit) else { return false }
        guard apex.y > rim.topY + (ballRadius * config.launchApexMarginInRadii) else { return false }

        // Must be predicted to arrive at the rim plane, near the hoop.
        guard let crossingFrame = findDownwardCrossing(
            fit: fit,
            yTarget: rim.scoringPlaneY,
            after: now,
            before: now + config.predictionHorizon
        ) else { return false }

        let predictedX = predictPosition(fit: fit, t: crossingFrame).x
        let reach = rim.horizontalRadius * config.rimZoneWidthInRimRadii

        return abs(predictedX - rim.center.x) <= reach
    }

    /// Fallback for shots released outside the tracked window — a descending ball
    /// already hanging over the hoop is an attempt regardless of how it got there.
    private func enteredRimZoneDescending(
        observation: BallObservation,
        rim: HoopGeometry,
        ballRadius: Double
    ) -> Bool {

        guard history.count >= 2 else { return false }

        let ball = observation.center

        // Descending, judged from the raw samples so this still works when the fit is
        // too short or too noisy to trust.
        let earlier = history[history.count - 2]
        guard ball.y < earlier.center.y else { return false }

        // Above the plane, but within reach of it.
        guard ball.y > rim.scoringPlaneY else { return false }
        guard ball.y < rim.scoringPlaneY + (ballRadius * config.rimZoneHeightInRadii) else { return false }

        // Horizontally over the hoop.
        let reach = rim.horizontalRadius * config.rimZoneWidthInRimRadii
        return abs(ball.x - rim.center.x) <= reach
    }

    private mutating func openAttempt(rim: HoopGeometry, late: Bool) -> ShotEvent {
        let trajectory = history
        let startFrame = trajectory.first?.frameID ?? 0

        let attempt = ShotAttempt(
            id: UUID(),
            startFrame: startFrame,
            endFrame: nil,
            result: .inProgress,
            trajectory: trajectory,
            crossings: [],
            rimContacts: 0,
            apexY: trajectory.map { Double($0.center.y) }.max(),
            wasDetectedLate: late,
            rim: rim,
            userVerdict: nil
        )

        currentAttempt = attempt
        state = .inFlight
        framesBelowRim = 0

        return .attemptStarted(attempt)
    }

    // MARK: Attempt progress

    private mutating func advanceAttempt(
        from previous: BallObservation?,
        to observation: BallObservation,
        rim: HoopGeometry
    ) -> [ShotEvent] {

        guard var attempt = currentAttempt else { return [] }

        // Keep the stored trajectory in step with the live history.
        if attempt.trajectory.last?.frameID != observation.frameID {
            attempt.trajectory.append(observation)
        }
        attempt.apexY = max(attempt.apexY ?? -.infinity, Double(observation.center.y))

        var events: [ShotEvent] = []
        let ballRadius = smoothedRadius(history: history)

        // --- Give up on a stalled attempt -------------------------------------
        if let previous, observation.frameID - previous.frameID > config.maxTrackingGapFrames {
            currentAttempt = attempt
            return [resolve(result: .abandoned, endFrame: observation.frameID)]
        }

        if observation.frameID - attempt.startFrame > config.attemptTimeoutFrames {
            currentAttempt = attempt
            return [resolve(result: .abandoned, endFrame: observation.frameID)]
        }

        // --- Rim / backboard contact ------------------------------------------
        // Near the hoop, a break from the parabola means the ball hit something. The
        // attempt stays open: a shot off the front rim can still drop through.
        if let fit = currentFit,
           isNearRim(observation: observation, rim: rim, ballRadius: ballRadius),
           detectFitBreak(history: history, fit: fit) {
            attempt.rimContacts += 1
            events.append(.rimContact(id: attempt.id))
        }

        // --- The verdict: a real downward crossing of the rim plane ------------
        if let previous,
           let crossing = crossingBetween(
               previous,
               observation,
               rim: rim,
               ballRadius: ballRadius
           ) {

            attempt.crossings.append(crossing)

            if crossing.isClean {
                currentAttempt = attempt
                events.append(resolve(result: .made, endFrame: Int(crossing.frame.rounded())))
                return events
            }
        }

        // --- Confirm a miss ---------------------------------------------------
        let missDepth = rim.scoringPlaneY - (ballRadius * config.missConfirmDepthInRadii)
        if observation.center.y < missDepth {
            framesBelowRim += 1
            state = .atRim
        } else {
            framesBelowRim = 0
            state = observation.center.y > rim.scoringPlaneY ? .inFlight : .atRim
        }

        currentAttempt = attempt

        if framesBelowRim >= config.missConfirmFrames {
            events.append(resolve(result: .missed, endFrame: observation.frameID))
        }

        return events
    }

    private func isNearRim(
        observation: BallObservation,
        rim: HoopGeometry,
        ballRadius: Double
    ) -> Bool {
        let dy = abs(observation.center.y - rim.scoringPlaneY)
        let dx = abs(observation.center.x - rim.center.x)
        return dy < (ballRadius * 4) && dx < (rim.horizontalRadius * 2.5)
    }

    // MARK: The crossing test

    /// If the ball fell through the rim plane between these two sightings, work out
    /// where — by linear interpolation between the two real positions.
    ///
    /// Interpolating matters: at 30fps a shot covers a good fraction of a rim diameter
    /// per frame, so snapping to whichever sample happens to be nearer the plane
    /// throws away most of the horizontal precision the verdict depends on.
    private func crossingBetween(
        _ before: BallObservation,
        _ after: BallObservation,
        rim: HoopGeometry,
        ballRadius: Double
    ) -> RimCrossing? {

        let plane = rim.scoringPlaneY

        // Strictly above, then at or below: a downward crossing.
        guard before.center.y > plane, after.center.y <= plane else { return nil }

        if config.requireBallisticCrossing,
           let fit = currentFit,
           !fit.isBallistic {
            return nil
        }

        let span = before.center.y - after.center.y
        let fraction = span > 0 ? (before.center.y - plane) / span : 0

        let x = before.center.x + (fraction * (after.center.x - before.center.x))
        let frame = Double(before.frameID) + (fraction * Double(after.frameID - before.frameID))

        // Interpolated in real time too, not derived from the frame index — the gap
        // between two frames is not guaranteed to be 1/fps.
        let timeSeconds: Double? = {
            guard let t0 = before.timeSeconds, let t1 = after.timeSeconds else { return nil }
            return t0 + (Double(fraction) * (t1 - t0))
        }()

        let offsetFromCentre = x - rim.center.x
        let normalisedOffset = rim.horizontalRadius > 0
            ? Double(offsetFromCentre / rim.horizontalRadius)
            : .infinity

        // The ball has to fit through the opening, so the usable half-width is the rim
        // radius less a share of the ball's own radius.
        let usableHalfWidth = max(
            rim.horizontalRadius - (ballRadius * config.makeBallClearance),
            ballRadius * 0.25
        )

        return RimCrossing(
            frame: frame,
            x: Double(x),
            normalisedOffset: normalisedOffset,
            isClean: abs(offsetFromCentre) <= usableHalfWidth,
            timeSeconds: timeSeconds
        )
    }

    // MARK: Resolution

    private mutating func resolve(result: ShotAttempt.Result, endFrame: Int) -> ShotEvent {
        var attempt = currentAttempt!
        attempt.result = result
        attempt.endFrame = endFrame

        currentAttempt = nil
        state = .idle
        framesBelowRim = 0
        predictedCrossingFrame = nil
        cooldownUntilFrame = endFrame + config.cooldownFrames

        return .attemptResolved(attempt)
    }

    // MARK: Live prediction (overlay only)

    private mutating func updatePrediction(rim: HoopGeometry, now: Int) {
        guard currentAttempt != nil, let fit = currentFit, fit.isBallistic else {
            predictedCrossingFrame = nil
            return
        }

        predictedCrossingFrame = findDownwardCrossing(
            fit: fit,
            yTarget: rim.scoringPlaneY,
            after: Double(now),
            before: Double(now) + config.predictionHorizon
        )
    }

    /// Points along the fitted arc, for drawing. Empty when there is no usable fit.
    func projectedArc(fromFrame: Int, sampleCount: Int = 40, aheadFrames: Double = 20) -> [CGPoint] {
        guard let fit = currentFit, let oldest = history.first else { return [] }

        let start = Double(oldest.frameID)
        let end = Double(fromFrame) + aheadFrames

        return linspace(start, end, sampleCount).map { t in
            let position = predictPosition(fit: fit, t: t)
            return CGPoint(x: position.x, y: position.y)
        }
    }
}
