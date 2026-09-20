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
struct AnalysisRun: Codable, Equatable, Identifiable {
    static let currentVersion = 2

    var version = AnalysisRun.currentVersion

    /// Each pass gets its own identity, so re-analysing a video adds a run rather than
    /// replacing the one before it.
    var id: UUID

    var assetIdentifier: String
    var analysedAt: Date

    var configuration: RunConfiguration
    var attempts: [ShotAttempt]
    var ballStats: BallDetectionStats?

    init(
        id: UUID = UUID(),
        assetIdentifier: String,
        analysedAt: Date = Date(),
        configuration: RunConfiguration,
        attempts: [ShotAttempt],
        ballStats: BallDetectionStats? = nil
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.analysedAt = analysedAt
        self.configuration = configuration
        self.attempts = attempts
        self.ballStats = ballStats
    }

    /// Header for the run index.
    var metadata: RunMetadata {
        let stats = ShotStats(attempts: attempts)
        return RunMetadata(
            id: id,
            analysedAt: analysedAt,
            configuration: configuration,
            attempts: stats.attempts,
            makes: stats.makes
        )
    }

    // Version 1 stored a bare `detectorConfig` and had no id. Decode those into the
    // current shape rather than discarding a user's existing analysis.
    private enum CodingKeys: String, CodingKey {
        case version, id, assetIdentifier, analysedAt, configuration, attempts, ballStats
        case detectorConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assetIdentifier = try container.decode(String.self, forKey: .assetIdentifier)
        analysedAt = try container.decode(Date.self, forKey: .analysedAt)
        attempts = try container.decode([ShotAttempt].self, forKey: .attempts)
        ballStats = try container.decodeIfPresent(BallDetectionStats.self, forKey: .ballStats)

        if let configuration = try container.decodeIfPresent(
            RunConfiguration.self, forKey: .configuration
        ) {
            self.configuration = configuration
        } else {
            let legacy = try container.decodeIfPresent(
                ShotDetectorConfig.self, forKey: .detectorConfig
            ) ?? ShotDetectorConfig()
            self.configuration = RunConfiguration(shotDetector: legacy)
        }
    }

    /// Written explicitly because `CodingKeys` carries the legacy `detectorConfig` key,
    /// which has no matching property to synthesise from. Only current keys are written.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(assetIdentifier, forKey: .assetIdentifier)
        try container.encode(analysedAt, forKey: .analysedAt)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(attempts, forKey: .attempts)
        try container.encodeIfPresent(ballStats, forKey: .ballStats)
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

    /// Pair each truth entry with the attempt that covers it, if any.
    ///
    /// The inverse view of `apply`: that answers "what did the user say about this
    /// attempt", this answers "what did this run say about that moment" — which is what
    /// comparing two runs needs, including the case where a run found nothing at all.
    static func pair(
        truth: [GroundTruthEntry],
        with attempts: [ShotAttempt],
        tolerance: Double = defaultTolerance
    ) -> [(entry: GroundTruthEntry, attempt: ShotAttempt?)] {

        var candidates: [(distance: Double, entryID: UUID, attemptIndex: Int)] = []

        for entry in truth {
            for (index, attempt) in attempts.enumerated() {
                guard let time = attempt.keyTime else { continue }
                let distance = abs(entry.timeSeconds - time)
                if distance <= tolerance {
                    candidates.append((distance, entry.id, index))
                }
            }
        }

        // Closest pairs win, and neither side is used twice.
        candidates.sort { $0.distance < $1.distance }

        var pairing: [UUID: Int] = [:]
        var usedAttempts = Set<Int>()

        for candidate in candidates {
            guard pairing[candidate.entryID] == nil else { continue }
            guard !usedAttempts.contains(candidate.attemptIndex) else { continue }

            pairing[candidate.entryID] = candidate.attemptIndex
            usedAttempts.insert(candidate.attemptIndex)
        }

        return truth.map { entry in
            (entry, pairing[entry.id].map { attempts[$0] })
        }
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

    /// How many times this video has been analysed.
    var runCount: Int = 1

    /// The run these numbers came from.
    var latestRunID: UUID?

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
        agreed: Int,
        runCount: Int = 1,
        latestRunID: UUID? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.analysedAt = analysedAt
        self.attempts = attempts
        self.makes = makes
        self.reviewed = reviewed
        self.agreed = agreed
        self.runCount = runCount
        self.latestRunID = latestRunID
    }

    /// Build from the attempts as currently ruled.
    init(
        assetIdentifier: String,
        analysedAt: Date = Date(),
        attempts shots: [ShotAttempt],
        runCount: Int = 1,
        latestRunID: UUID? = nil
    ) {
        let stats = ShotStats(attempts: shots)
        let accuracy = DetectorAccuracy(attempts: shots)

        self.init(
            assetIdentifier: assetIdentifier,
            analysedAt: analysedAt,
            attempts: stats.attempts,
            makes: stats.makes,
            reviewed: accuracy.reviewed,
            agreed: accuracy.agreed,
            runCount: runCount,
            latestRunID: latestRunID
        )
    }
}

// MARK: - Run configuration

/// Everything that affects what an analysis run produces.
///
/// Deliberately wider than `ShotDetectorConfig`. The model file, the crop geometry and
/// the detection confidence floors all move the numbers, and none of them live in the
/// shot detector's settings — so two runs could record identical `ShotDetectorConfig`
/// values while having been produced by completely different pipelines. Comparing
/// accuracy between runs is only meaningful if you know what actually differed.
struct RunConfiguration: Codable, Equatable {

    /// Where the rim came from, which changes the scoring plane and therefore verdicts.
    enum RimSource: String, Codable {
        case detected
        case userPlaced
        case none
    }

    var shotDetector: ShotDetectorConfig
    var ballROI: BallROIPredictor.Config

    var fullFrameBallConfidence: Double
    var croppedBallConfidence: Double

    var modelIdentifier: String
    var rimSource: RimSource

    /// App build that produced the run, to catch changes not captured above.
    var appVersion: String

    init(
        shotDetector: ShotDetectorConfig = ShotDetectorConfig(),
        ballROI: BallROIPredictor.Config = BallROIPredictor.Config(),
        fullFrameBallConfidence: Double = 0.45,
        croppedBallConfidence: Double = 0.25,
        modelIdentifier: String = "unknown",
        rimSource: RimSource = .none,
        appVersion: String = RunConfiguration.currentAppVersion
    ) {
        self.shotDetector = shotDetector
        self.ballROI = ballROI
        self.fullFrameBallConfidence = fullFrameBallConfidence
        self.croppedBallConfidence = croppedBallConfidence
        self.modelIdentifier = modelIdentifier
        self.rimSource = rimSource
        self.appVersion = appVersion
    }

    /// Lenient, so a run saved before a setting existed still loads.
    private enum CodingKeys: String, CodingKey {
        case shotDetector, ballROI, fullFrameBallConfidence, croppedBallConfidence
        case modelIdentifier, rimSource, appVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RunConfiguration()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }

        shotDetector = value(.shotDetector, defaults.shotDetector)
        ballROI = value(.ballROI, defaults.ballROI)
        fullFrameBallConfidence = value(.fullFrameBallConfidence, defaults.fullFrameBallConfidence)
        croppedBallConfidence = value(.croppedBallConfidence, defaults.croppedBallConfidence)
        modelIdentifier = value(.modelIdentifier, defaults.modelIdentifier)
        rimSource = value(.rimSource, defaults.rimSource)
        appVersion = value(.appVersion, defaults.appVersion)
    }

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Stable identity for "the same experiment".
    ///
    /// Two runs sharing a fingerprint were produced the same way, so a difference in
    /// their results is noise rather than the effect of a change.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(self) else { return "unknown" }

        // FNV-1a: short, stable across launches, and good enough to tell configurations
        // apart. Swift's Hasher is seeded per-process and would not be.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// A short description of how this run differs from another.
    func differences(from other: RunConfiguration) -> [String] {
        var changes: [String] = []

        if modelIdentifier != other.modelIdentifier {
            changes.append("model \(other.modelIdentifier) → \(modelIdentifier)")
        }
        if shotDetector.makeBallClearance != other.shotDetector.makeBallClearance {
            changes.append(String(
                format: "make clearance %.2f → %.2f",
                other.shotDetector.makeBallClearance, shotDetector.makeBallClearance
            ))
        }
        if shotDetector.rimZoneWidthInRimRadii != other.shotDetector.rimZoneWidthInRimRadii {
            changes.append(String(
                format: "rim zone %.2f → %.2f",
                other.shotDetector.rimZoneWidthInRimRadii, shotDetector.rimZoneWidthInRimRadii
            ))
        }
        if ballROI.baseSideFraction != other.ballROI.baseSideFraction {
            changes.append(String(
                format: "crop %.2f → %.2f",
                other.ballROI.baseSideFraction, ballROI.baseSideFraction
            ))
        }
        if rimSource != other.rimSource {
            changes.append("rim \(other.rimSource.rawValue) → \(rimSource.rawValue)")
        }
        if appVersion != other.appVersion {
            changes.append("build \(other.appVersion) → \(appVersion)")
        }

        return changes
    }
}

/// Lightweight header for one run, so the list of runs for a video can be drawn without
/// parsing every trajectory in every run.
struct RunMetadata: Codable, Equatable, Identifiable {
    var id: UUID
    var analysedAt: Date
    var configuration: RunConfiguration

    var attempts: Int
    var makes: Int

    var fieldGoalPercentage: Double {
        attempts > 0 ? (Double(makes) / Double(attempts)) * 100 : 0
    }
}
