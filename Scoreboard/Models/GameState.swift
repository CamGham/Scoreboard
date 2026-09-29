//
//  GameState.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/01/2026.
//

import Foundation
import SwiftUI

struct ShotStats: Equatable {
    var attempts: Int = 0
    var makes: Int = 0

    var misses: Int { attempts - makes }

    /// Field-goal percentage, 0–100. Zero attempts reads as 0.
    var fieldGoalPercentage: Double {
        attempts > 0 ? (Double(makes) / Double(attempts)) * 100 : 0
    }

    /// Points, counting every make as two. Distinguishing twos from threes needs court
    /// calibration the pipeline doesn't have yet.
    var points: Int { makes * 2 }

    init() {}

    /// Totals honour the user's rulings, so a correction updates the score immediately.
    init(attempts shots: [ShotAttempt]) {
        let counted = shots.filter(\.isCountedAttempt)
        self.attempts = counted.count
        self.makes = counted.filter(\.isCountedMake).count
    }
}

/// How often the detector agreed with the user, over the shots they have ruled on.
///
/// This is the evaluation the pipeline previously had no way to produce. Every
/// correction is a labelled example, so simply using the app builds the ground-truth set
/// needed to judge a threshold change or a retrained model.
struct DetectorAccuracy: Equatable {
    var reviewed = 0
    var agreed = 0

    /// Ruled "not a shot" — the detector invented an attempt.
    var falsePositives = 0

    /// A real shot whose make/miss call was wrong.
    var wrongCalls = 0

    var agreementRate: Double {
        reviewed > 0 ? (Double(agreed) / Double(reviewed)) * 100 : 0
    }

    init() {}

    init(attempts shots: [ShotAttempt]) {
        let ruled = shots.filter { $0.userVerdict != nil }

        reviewed = ruled.count
        agreed = ruled.filter { !$0.isCorrected }.count
        falsePositives = ruled.filter { $0.userVerdict == .notAShot }.count
        wrongCalls = ruled.filter { $0.isCorrected && $0.userVerdict != .notAShot }.count
    }
}

/// Main-actor view of the game, fed by `ShotTracker` from the frame-processing thread.
@MainActor
@Observable
final class GameState {

    /// Latest frame's worth of overlay data.
    private(set) var snapshot = GameSnapshot()

    /// Every attempt the detector has resolved, newest last.
    private(set) var shotTimeline: [ShotAttempt] = []

    /// Attempts that never resolved. The user can still rule on these, which promotes
    /// them into the totals.
    private(set) var abandonedAttempts: [ShotAttempt] = []

    /// Frame of the most recent made basket, for a score flash in the UI.
    private(set) var lastMadeFrame: Int?

    // Convenience accessors so views don't have to reach through `snapshot`.
    var ballHistory: [BallObservation] { snapshot.ballHistory }
    var rim: HoopGeometry? { snapshot.rim }
    var ballState: BallState { snapshot.ballState }
    var arcPoints: [CGPoint] { snapshot.arcPoints }
    var currentAttempt: ShotAttempt? { snapshot.currentAttempt }
    var predictedCrossingFrame: Double? { snapshot.predictedCrossingFrame }

    /// Everything the user could pass judgement on.
    var reviewableAttempts: [ShotAttempt] {
        shotTimeline + abandonedAttempts
    }

    /// Derived rather than accumulated, so a correction to an old shot is reflected
    /// immediately. Incrementing counters as events arrived could not survive a verdict
    /// changing after the fact.
    var stats: ShotStats {
        ShotStats(attempts: reviewableAttempts)
    }

    var accuracy: DetectorAccuracy {
        DetectorAccuracy(attempts: reviewableAttempts)
    }

    /// Constructible off the main actor — `VisionTracker` owns one and is created on the
    /// frame-processing thread. Every stored property starts from a plain value, so
    /// there is nothing isolated to touch here; all *mutation* stays main-actor bound.
    nonisolated init() {}

    func apply(_ incoming: GameSnapshot) {
        // Snapshots are delivered by hopping onto the main actor, which does not
        // guarantee arrival order. Dropping stale ones keeps the overlay monotonic.
        guard incoming.sequence > snapshot.sequence else { return }
        snapshot = incoming
    }

    func handle(_ event: ShotEvent) {
        switch event {
        case .attemptStarted, .rimContact:
            break

        case .attemptResolved(let resolved):
            // Reapply anything the user already ruled on this moment of the clip.
            let attempt = GroundTruthMatcher.apply(storedTruth, to: [resolved]).first ?? resolved

            switch attempt.result {
            case .made:
                shotTimeline.append(attempt)
                lastMadeFrame = attempt.endFrame

            case .missed:
                shotTimeline.append(attempt)

            case .abandoned:
                abandonedAttempts.append(attempt)

            case .inProgress:
                break
            }
        }
    }

    // MARK: Corrections

    func attempt(withID id: UUID) -> ShotAttempt? {
        reviewableAttempts.first { $0.id == id }
    }

    /// Called after a ruling changes, so it can be written to disk.
    var onVerdictChanged: ((ShotAttempt) -> Void)?

    /// Rulings loaded from disk, applied to attempts as they are detected.
    ///
    /// Matched by time rather than id, because these were recorded against a previous
    /// run whose attempt ids no longer exist.
    var storedTruth: [GroundTruthEntry] = []

    /// Record — or clear, with nil — the user's ruling on a shot.
    func setVerdict(_ verdict: ShotAttempt.UserVerdict?, for id: UUID) {
        if let index = shotTimeline.firstIndex(where: { $0.id == id }) {
            shotTimeline[index].userVerdict = verdict
            onVerdictChanged?(shotTimeline[index])
            return
        }
        if let index = abandonedAttempts.firstIndex(where: { $0.id == id }) {
            abandonedAttempts[index].userVerdict = verdict
            onVerdictChanged?(abandonedAttempts[index])
        }
    }

    // MARK: Re-analysis

    /// What a merge changed, for telling the user what just happened.
    struct MergeOutcome: Equatable {
        var removed = 0
        var added = 0

        var changedAnything: Bool { removed > 0 || added > 0 }
    }

    /// Swap everything detected inside a window for the results of a fresh pass over it.
    ///
    /// Scoped by time rather than by attempt id: the new pass has never seen the old
    /// attempts, so the window is the only thing the two runs agree on. Anything whose
    /// key moment falls inside it is the old pass's opinion of that footage, and is
    /// replaced wholesale — a partial merge would leave the two runs' disagreements
    /// sitting side by side as duplicate shots.
    @discardableResult
    func replaceAttempts(
        in range: ClosedRange<Double>,
        with attempts: [ShotAttempt]
    ) -> MergeOutcome {

        // Rulings are keyed by time, so whatever the user decided about this stretch is
        // reapplied to whatever the new pass found in the same place. This is the reason
        // corrections were never stored inside a run.
        let incoming = GroundTruthMatcher.apply(storedTruth, to: attempts)

        func isInside(_ attempt: ShotAttempt) -> Bool {
            guard let key = attempt.keyTime else { return false }
            return range.contains(key)
        }

        let removed = shotTimeline.filter(isInside).count
            + abandonedAttempts.filter(isInside).count

        shotTimeline.removeAll(where: isInside)
        abandonedAttempts.removeAll(where: isInside)

        var added = 0
        for attempt in incoming {
            switch attempt.result {
            case .made, .missed:
                shotTimeline.append(attempt)
                added += 1
            case .abandoned:
                abandonedAttempts.append(attempt)
                added += 1
            case .inProgress:
                // Still open when the window ran out: the pass saw only part of it, so
                // it is no one's idea of a result.
                break
            }
        }

        // Both lists are read in order, so a section spliced into the middle has to be
        // sorted back into place rather than appended.
        shotTimeline.sort(by: Self.chronologically)
        abandonedAttempts.sort(by: Self.chronologically)

        lastMadeFrame = shotTimeline.last(where: { $0.effectiveResult == .made })?.endFrame

        return MergeOutcome(removed: removed, added: added)
    }

    /// Untimed attempts sort last — they can't be placed, and putting them first would
    /// claim they happened at the start of the clip.
    private static func chronologically(_ lhs: ShotAttempt, _ rhs: ShotAttempt) -> Bool {
        (lhs.keyTime ?? .greatestFiniteMagnitude) < (rhs.keyTime ?? .greatestFiniteMagnitude)
    }

    /// Reapply stored rulings to the attempts detected so far, matching by time.
    func applyStoredTruth(_ truth: [GroundTruthEntry]) {
        storedTruth = truth
        shotTimeline = GroundTruthMatcher.apply(truth, to: shotTimeline)
        abandonedAttempts = GroundTruthMatcher.apply(truth, to: abandonedAttempts)
    }

    /// Populate from a saved run, reapplying the user's stored rulings.
    ///
    /// Attempts are sorted back into resolved and abandoned the same way live events
    /// would have, so every view that works on a live game works on a saved one.
    func load(run: AnalysisRun, truth: GroundTruthDocument) {
        reset()

        storedTruth = truth.shots
        let matched = GroundTruthMatcher.apply(truth.shots, to: run.attempts)

        shotTimeline = matched.filter { $0.result == .made || $0.result == .missed }
        abandonedAttempts = matched.filter { $0.result == .abandoned }
        lastMadeFrame = shotTimeline.last(where: { $0.result == .made })?.endFrame
    }

    func reset() {
        snapshot = GameSnapshot()
        shotTimeline.removeAll()
        abandonedAttempts.removeAll()
        lastMadeFrame = nil
    }
}
