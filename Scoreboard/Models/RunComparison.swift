//
//  RunComparison.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation

/// Two analysis runs of the same video, judged shot by shot against the user's rulings.
///
/// Totals alone can't tell you whether a change helped: a run that fixes three shots and
/// breaks three others has an identical agreement rate to one that changed nothing. What
/// matters is *which* shots moved, and in which direction.
struct RunComparison {

    /// What one run said about one shot the user has ruled on.
    struct Call: Equatable {
        enum Outcome: Equatable {
            /// The run produced an attempt here, with this verdict.
            case found(ShotAttempt.Result)
            /// The run produced nothing here.
            case notFound
        }

        let outcome: Outcome
        let isCorrect: Bool

        init(_ attempt: ShotAttempt?, matching entry: GroundTruthEntry) {
            outcome = attempt.map { .found($0.result) } ?? .notFound

            // Correctness is judged against the *detector's* call, not the user's
            // correction — the detector is what's on trial. And for a moment ruled
            // "not a shot", being right means having found nothing at all.
            switch entry.verdict {
            case .made: isCorrect = (attempt?.result == .made)
            case .missed: isCorrect = (attempt?.result == .missed)
            case .notAShot: isCorrect = (attempt == nil)
            }
        }

        var label: String {
            switch outcome {
            case .found(let result): return result.rawValue.capitalized
            case .notFound: return "Not found"
            }
        }
    }

    enum Change: String {
        case improved
        case regressed
        case bothRight
        case bothWrong

        var isInteresting: Bool {
            self == .improved || self == .regressed
        }
    }

    struct Row: Identifiable {
        var id: UUID { truth.id }

        let truth: GroundTruthEntry
        let baseline: Call
        let candidate: Call

        var change: Change {
            switch (baseline.isCorrect, candidate.isCorrect) {
            case (false, true): return .improved
            case (true, false): return .regressed
            case (true, true): return .bothRight
            case (false, false): return .bothWrong
            }
        }
    }

    let baseline: RunMetadata
    let candidate: RunMetadata
    let rows: [Row]

    /// How the candidate's settings differ from the baseline's.
    let configurationChanges: [String]

    /// Attempts either run produced at moments the user hasn't ruled on. These can't be
    /// judged either way, and a comparison resting on a handful of reviewed shots
    /// deserves less confidence than one resting on fifty.
    let unreviewedAttempts: Int

    var improved: [Row] { rows.filter { $0.change == .improved } }
    var regressed: [Row] { rows.filter { $0.change == .regressed } }

    var bothRight: Int { rows.filter { $0.change == .bothRight }.count }
    var bothWrong: Int { rows.filter { $0.change == .bothWrong }.count }

    /// Positive means the candidate is better on the shots that are actually judged.
    var netChange: Int { improved.count - regressed.count }

    var baselineCorrect: Int { rows.filter(\.baseline.isCorrect).count }
    var candidateCorrect: Int { rows.filter(\.candidate.isCorrect).count }

    var baselineAccuracy: Double {
        rows.isEmpty ? 0 : (Double(baselineCorrect) / Double(rows.count)) * 100
    }

    var candidateAccuracy: Double {
        rows.isEmpty ? 0 : (Double(candidateCorrect) / Double(rows.count)) * 100
    }

    /// True when the two runs were produced the same way, so any difference is noise
    /// rather than the effect of a change.
    var isSameConfiguration: Bool {
        baseline.configuration.fingerprint == candidate.configuration.fingerprint
    }
}

enum RunComparator {

    static func compare(
        baseline: AnalysisRun,
        candidate: AnalysisRun,
        truth: [GroundTruthEntry],
        tolerance: Double = GroundTruthMatcher.defaultTolerance
    ) -> RunComparison {

        let baselinePairs = GroundTruthMatcher.pair(
            truth: truth, with: baseline.attempts, tolerance: tolerance
        )
        let candidatePairs = GroundTruthMatcher.pair(
            truth: truth, with: candidate.attempts, tolerance: tolerance
        )

        let rows = truth
            .sorted { $0.timeSeconds < $1.timeSeconds }
            .map { entry in
                RunComparison.Row(
                    truth: entry,
                    baseline: RunComparison.Call(
                        baselinePairs.first { $0.entry.id == entry.id }?.attempt,
                        matching: entry
                    ),
                    candidate: RunComparison.Call(
                        candidatePairs.first { $0.entry.id == entry.id }?.attempt,
                        matching: entry
                    )
                )
            }

        // Attempts in the candidate that no ruling covers — the part of this run the
        // comparison simply can't speak to.
        let matchedInCandidate = Set(candidatePairs.compactMap { $0.attempt?.id })
        let unreviewed = candidate.attempts.filter { !matchedInCandidate.contains($0.id) }.count

        return RunComparison(
            baseline: baseline.metadata,
            candidate: candidate.metadata,
            rows: rows,
            configurationChanges: candidate.configuration.differences(from: baseline.configuration),
            unreviewedAttempts: unreviewed
        )
    }
}
