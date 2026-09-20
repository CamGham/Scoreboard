//
//  ShotArchive.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation

// MARK: - Ground truth

/// One thing the user has told us actually happened, pinned to a moment in the clip.
///
/// Keyed by *time*, never by attempt id. Re-analysing a video mints new attempt ids, so
/// a ruling attached to one is orphaned by the first re-run — which is exactly when you
/// re-run: after changing a threshold or retraining. Time is the only identifier that
/// means the same thing before and after.
struct GroundTruthEntry: Codable, Equatable, Identifiable {
    var id = UUID()

    /// Seconds from the start of the media.
    var timeSeconds: Double

    var verdict: ShotAttempt.UserVerdict

    /// When the user made this call, for resolving conflicts on re-import.
    var recordedAt: Date = Date()
}

/// Everything the *user* has supplied about one video. Outlives any detector run.
struct GroundTruthDocument: Codable, Equatable {
    static let currentVersion = 1

    var version = GroundTruthDocument.currentVersion
    var assetIdentifier: String

    /// A hand-placed rim. Re-analysing shouldn't make the user position it again.
    var rim: HoopGeometry?

    var shots: [GroundTruthEntry] = []

    init(assetIdentifier: String, rim: HoopGeometry? = nil, shots: [GroundTruthEntry] = []) {
        self.assetIdentifier = assetIdentifier
        self.rim = rim
        self.shots = shots
    }
}

// MARK: - Analysis run

/// One pass of the detector over one video, with the settings that produced it.
///
/// The config is stored because comparing accuracy across detector versions is the whole
/// point of keeping this data. Numbers without the settings that produced them can't be
/// compared to anything.
struct AnalysisRun: Codable, Equatable {
    static let currentVersion = 1

    var version = AnalysisRun.currentVersion
    var assetIdentifier: String
    var analysedAt: Date

    var detectorConfig: ShotDetectorConfig
    var attempts: [ShotAttempt]
    var ballStats: BallDetectionStats?

    init(
        assetIdentifier: String,
        analysedAt: Date = Date(),
        detectorConfig: ShotDetectorConfig,
        attempts: [ShotAttempt],
        ballStats: BallDetectionStats? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.analysedAt = analysedAt
        self.detectorConfig = detectorConfig
        self.attempts = attempts
        self.ballStats = ballStats
    }
}

// MARK: - Matching

/// Reconciles stored ground truth with a fresh set of detected attempts.
enum GroundTruthMatcher {

    /// How far apart a truth entry and an attempt may be and still be the same shot.
    ///
    /// Shots in a real game are seconds apart, and a re-analysis moves a given shot's
    /// timing by fractions of a second at most, so a second of slack matches reliably
    /// without bridging to a neighbouring shot.
    static let defaultTolerance: Double = 1.0

    /// Apply stored rulings to freshly detected attempts.
    ///
    /// Each truth entry is consumed at most once, nearest attempt first, so two attempts
    /// close together can't both claim the same ruling.
    static func apply(
        _ truth: [GroundTruthEntry],
        to attempts: [ShotAttempt],
        tolerance: Double = defaultTolerance
    ) -> [ShotAttempt] {

        guard !truth.isEmpty else { return attempts }

        var result = attempts
        var claimed = Set<UUID>()

        // Pair everything within tolerance, then take the closest pairs first so the
        // best matches win rather than whichever happened to be earlier in the array.
        var candidates: [(distance: Double, attemptIndex: Int, entry: GroundTruthEntry)] = []

        for (index, attempt) in attempts.enumerated() {
            guard let time = attempt.keyTime else { continue }

            for entry in truth {
                let distance = abs(entry.timeSeconds - time)
                if distance <= tolerance {
                    candidates.append((distance, index, entry))
                }
            }
        }

        candidates.sort { $0.distance < $1.distance }

        var usedAttempts = Set<Int>()

        for candidate in candidates {
            guard !usedAttempts.contains(candidate.attemptIndex) else { continue }
            guard !claimed.contains(candidate.entry.id) else { continue }

            result[candidate.attemptIndex].userVerdict = candidate.entry.verdict
            usedAttempts.insert(candidate.attemptIndex)
            claimed.insert(candidate.entry.id)
        }

        return result
    }

    /// Fold a ruling into the stored truth, replacing any entry already covering that
    /// moment. Passing nil erases the ruling there.
    static func record(
        verdict: ShotAttempt.UserVerdict?,
        atTime time: Double,
        into truth: [GroundTruthEntry],
        tolerance: Double = defaultTolerance
    ) -> [GroundTruthEntry] {

        var result = truth.filter { abs($0.timeSeconds - time) > tolerance }

        if let verdict {
            result.append(GroundTruthEntry(timeSeconds: time, verdict: verdict))
        }

        return result.sorted { $0.timeSeconds < $1.timeSeconds }
    }

    /// How a run scored against the stored truth.
    ///
    /// Counts truth entries the run *missed* as well as the ones it got wrong — a
    /// detector that silently stops finding shots would otherwise look like it improved.
    static func score(
        run attempts: [ShotAttempt],
        against truth: [GroundTruthEntry],
        tolerance: Double = defaultTolerance
    ) -> RunScore {

        let matched = apply(truth, to: attempts, tolerance: tolerance)
        let ruled = matched.filter { $0.userVerdict != nil }

        let realShots = truth.filter { $0.verdict != .notAShot }
        let foundTimes = ruled.compactMap { attempt -> Double? in
            attempt.userVerdict == .notAShot ? nil : attempt.keyTime
        }

        let missed = realShots.filter { entry in
            !foundTimes.contains { abs($0 - entry.timeSeconds) <= tolerance }
        }

        return RunScore(
            reviewed: ruled.count,
            agreed: ruled.filter { !$0.isCorrected }.count,
            wrongCalls: ruled.filter { $0.isCorrected && $0.userVerdict != .notAShot }.count,
            falsePositives: ruled.filter { $0.userVerdict == .notAShot }.count,
            missedShots: missed.count
        )
    }
}

struct RunScore: Equatable {
    var reviewed = 0
    var agreed = 0
    var wrongCalls = 0
    var falsePositives = 0

    /// Shots the user recorded that this run never produced an attempt for.
    var missedShots = 0

    var agreementRate: Double {
        reviewed > 0 ? (Double(agreed) / Double(reviewed)) * 100 : 0
    }
}

// MARK: - Listing

/// A cheap headline for one saved video, so the library list doesn't have to parse every
/// run's full trajectory data just to draw a row.
struct SavedGameSummary: Codable, Equatable, Identifiable {
    var id: String { assetIdentifier }

    var assetIdentifier: String
    var analysedAt: Date

    var attempts: Int
    var makes: Int

    /// How many shots the user has ruled on, and how often the detector agreed.
    var reviewed: Int
    var agreed: Int

    var misses: Int { attempts - makes }

    var fieldGoalPercentage: Double {
        attempts > 0 ? (Double(makes) / Double(attempts)) * 100 : 0
    }

    var agreementRate: Double {
        reviewed > 0 ? (Double(agreed) / Double(reviewed)) * 100 : 0
    }

    init(
        assetIdentifier: String,
        analysedAt: Date = Date(),
        attempts: Int,
        makes: Int,
        reviewed: Int,
        agreed: Int
    ) {
        self.assetIdentifier = assetIdentifier
        self.analysedAt = analysedAt
        self.attempts = attempts
        self.makes = makes
        self.reviewed = reviewed
        self.agreed = agreed
    }

    /// Build from the attempts as currently ruled.
    init(assetIdentifier: String, analysedAt: Date = Date(), attempts shots: [ShotAttempt]) {
        let stats = ShotStats(attempts: shots)
        let accuracy = DetectorAccuracy(attempts: shots)

        self.init(
            assetIdentifier: assetIdentifier,
            analysedAt: analysedAt,
            attempts: stats.attempts,
            makes: stats.makes,
            reviewed: accuracy.reviewed,
            agreed: accuracy.agreed
        )
    }
}
