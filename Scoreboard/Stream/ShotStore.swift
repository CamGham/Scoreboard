//
//  ShotStore.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation

/// Reads and writes per-video analysis on disk, as JSON.
///
/// One directory per video, holding two files with deliberately different lifetimes:
///
///  - `runs/<id>.json` — what the detector produced. Each analysis adds one; earlier
///    runs are kept so a change can be measured against what came before.
///  - `truth.json` — what the user told us. Never touched by re-analysis.
///
/// Keeping them apart is the point. Corrections are the expensive data: they cost a
/// person's attention, and they are the only yardstick for whether a threshold change or
/// a retrained model actually helped. Storing them inside the run would throw them away
/// on every re-run.
///
/// JSON rather than a database because the domain types are already plain structs — so
/// there is no mapping layer to drift — and because the main thing you do with ground
/// truth is take it off the device to evaluate against, where this is already the
/// export format.
struct ShotStore {

    enum StoreError: Error {
        case noAssetIdentifier
    }

    private let root: URL
    private let fileManager: FileManager

    init(
        root: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager

        if let root {
            self.root = root
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appending(path: "Scoreboard/videos", directoryHint: .isDirectory)
        }
    }

    // MARK: Locations

    /// Asset identifiers contain characters that are awkward in paths, so they are
    /// encoded rather than used raw.
    private func directory(for assetIdentifier: String) -> URL {
        let safe = assetIdentifier
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? String(assetIdentifier.hashValue)

        return root.appending(path: safe, directoryHint: .isDirectory)
    }

    private func runsDirectory(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "runs", directoryHint: .isDirectory)
    }

    private func runURL(for assetIdentifier: String, runID: UUID) -> URL {
        runsDirectory(for: assetIdentifier).appending(path: "\(runID.uuidString).json")
    }

    /// Headers for every run, so the run list needn't parse each one's trajectories.
    private func runIndexURL(for assetIdentifier: String) -> URL {
        runsDirectory(for: assetIdentifier).appending(path: "index.json")
    }

    /// Where version 1 kept its single run.
    private func legacyRunURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "run.json")
    }

    private func truthURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "truth.json")
    }

    private func summaryURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "summary.json")
    }

    /// Sections the user has marked for another look. Third lifetime alongside runs and
    /// truth: work still to do, rather than what happened or what was decided.
    private func planURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "reanalysis.json")
    }

    // MARK: Listing

    /// Headlines for every saved video, newest first.
    ///
    /// Reads only the small summary files. Deriving these from the runs would mean
    /// parsing every trajectory in the library to draw a list.
    func summaries() -> [SavedGameSummary] {
        storedAssetIdentifiers()
            .compactMap { loadSummary(for: $0) }
            .sorted { $0.analysedAt > $1.analysedAt }
    }

    func loadSummary(for assetIdentifier: String) -> SavedGameSummary? {
        read(summaryURL(for: assetIdentifier))
    }

    func saveSummary(_ summary: SavedGameSummary) throws {
        try write(summary, to: summaryURL(for: summary.assetIdentifier))
    }

    // MARK: Ground truth

    func loadTruth(for assetIdentifier: String) -> GroundTruthDocument {
        guard let document: GroundTruthDocument = read(truthURL(for: assetIdentifier)) else {
            return GroundTruthDocument(assetIdentifier: assetIdentifier)
        }
        return document
    }

    func saveTruth(_ document: GroundTruthDocument) throws {
        try write(document, to: truthURL(for: document.assetIdentifier))
    }

    // MARK: Re-analysis marks

    func loadPlan(for assetIdentifier: String) -> ReanalysisPlan {
        guard let plan: ReanalysisPlan = read(planURL(for: assetIdentifier)) else {
            return ReanalysisPlan(assetIdentifier: assetIdentifier)
        }
        return plan
    }

    func savePlan(_ plan: ReanalysisPlan) throws {
        try write(plan, to: planURL(for: plan.assetIdentifier))
    }

    // MARK: Analysis runs

    /// Runs kept per video, newest first. Older ones are pruned.
    ///
    /// A run carries every trajectory, so it is the largest thing stored — tuning a
    /// threshold across dozens of passes on one video would otherwise accumulate
    /// unboundedly.
    var retentionLimit: Int { 10 }

    /// Headers for every stored run, newest first.
    func runs(for assetIdentifier: String) -> [RunMetadata] {
        migrateLegacyRunIfNeeded(for: assetIdentifier)

        let index: [RunMetadata] = read(runIndexURL(for: assetIdentifier)) ?? []
        return index.sorted { $0.analysedAt > $1.analysedAt }
    }

    func hasAnalysis(for assetIdentifier: String) -> Bool {
        !runs(for: assetIdentifier).isEmpty
    }

    func loadRun(_ runID: UUID, for assetIdentifier: String) -> AnalysisRun? {
        read(runURL(for: assetIdentifier, runID: runID))
    }

    /// The most recent run, or nil if the video has never been analysed.
    func latestRun(for assetIdentifier: String) -> AnalysisRun? {
        guard let newest = runs(for: assetIdentifier).first else { return nil }
        return loadRun(newest.id, for: assetIdentifier)
    }

    /// Store a run *alongside* any earlier ones.
    func saveRun(_ run: AnalysisRun) throws {
        migrateLegacyRunIfNeeded(for: run.assetIdentifier)

        try write(run, to: runURL(for: run.assetIdentifier, runID: run.id))

        var index: [RunMetadata] = read(runIndexURL(for: run.assetIdentifier)) ?? []
        index.removeAll { $0.id == run.id }
        index.append(run.metadata)
        index.sort { $0.analysedAt > $1.analysedAt }

        // Drop the oldest beyond the limit, deleting their files too.
        if index.count > retentionLimit {
            for stale in index.dropFirst(retentionLimit) {
                try? fileManager.removeItem(
                    at: runURL(for: run.assetIdentifier, runID: stale.id)
                )
            }
            index = Array(index.prefix(retentionLimit))
        }

        try write(index, to: runIndexURL(for: run.assetIdentifier))
    }

    func deleteRun(_ runID: UUID, for assetIdentifier: String) throws {
        try? fileManager.removeItem(at: runURL(for: assetIdentifier, runID: runID))

        var index: [RunMetadata] = read(runIndexURL(for: assetIdentifier)) ?? []
        index.removeAll { $0.id == runID }
        try write(index, to: runIndexURL(for: assetIdentifier))
    }

    /// Everything known about a video: a run with the user's rulings reapplied.
    ///
    /// Defaults to the newest run; pass `runID` to open an earlier one.
    func load(
        for assetIdentifier: String,
        runID: UUID? = nil
    ) -> (run: AnalysisRun?, truth: GroundTruthDocument) {

        let truth = loadTruth(for: assetIdentifier)

        let loaded = runID.flatMap { loadRun($0, for: assetIdentifier) }
            ?? latestRun(for: assetIdentifier)

        guard var run = loaded else { return (nil, truth) }

        // Rulings are matched onto the run by time, so they survive the attempt ids
        // having been regenerated by a re-analysis.
        run.attempts = GroundTruthMatcher.apply(truth.shots, to: run.attempts)

        return (run, truth)
    }

    /// Move a version 1 single-run file into the per-run layout.
    ///
    /// Silent and idempotent: an existing analysis shouldn't be lost to a storage change,
    /// and the user has no reason to know one happened.
    private func migrateLegacyRunIfNeeded(for assetIdentifier: String) {
        let legacy = legacyRunURL(for: assetIdentifier)
        guard fileManager.fileExists(atPath: legacy.path()) else { return }

        defer { try? fileManager.removeItem(at: legacy) }

        guard let run: AnalysisRun = read(legacy) else { return }

        try? write(run, to: runURL(for: assetIdentifier, runID: run.id))

        var index: [RunMetadata] = read(runIndexURL(for: assetIdentifier)) ?? []
        if !index.contains(where: { $0.id == run.id }) {
            index.append(run.metadata)
            index.sort { $0.analysedAt > $1.analysedAt }
            try? write(index, to: runIndexURL(for: assetIdentifier))
        }
    }

    func delete(assetIdentifier: String) throws {
        let directory = directory(for: assetIdentifier)
        guard fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// Identifiers of every video with something stored.
    func storedAssetIdentifiers() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents.compactMap { $0.lastPathComponent.removingPercentEncoding }
    }

    /// Rewrite the library headline for a video from its current runs and rulings.
    func refreshSummary(for assetIdentifier: String, attempts: [ShotAttempt]) throws {
        let stored = runs(for: assetIdentifier)

        try saveSummary(
            SavedGameSummary(
                assetIdentifier: assetIdentifier,
                analysedAt: stored.first?.analysedAt ?? Date(),
                attempts: attempts,
                runCount: stored.count,
                latestRunID: stored.first?.id
            )
        )
    }

    // MARK: IO

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // A file written by an older build shouldn't crash the app or wipe the user's
        // corrections; treat it as absent and let it be rewritten.
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Atomic, so an interrupted write can't leave a half-file where the user's
        // corrections used to be.
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
