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
///  - `run.json` — what the detector produced. Replaced wholesale on re-analysis.
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

    private func runURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "run.json")
    }

    private func truthURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "truth.json")
    }

    private func summaryURL(for assetIdentifier: String) -> URL {
        directory(for: assetIdentifier).appending(path: "summary.json")
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

    // MARK: Analysis runs

    func loadRun(for assetIdentifier: String) -> AnalysisRun? {
        read(runURL(for: assetIdentifier))
    }

    func saveRun(_ run: AnalysisRun) throws {
        try write(run, to: runURL(for: run.assetIdentifier))
    }

    /// Everything known about a video: the last run with the user's rulings reapplied.
    func load(for assetIdentifier: String) -> (run: AnalysisRun?, truth: GroundTruthDocument) {
        let truth = loadTruth(for: assetIdentifier)

        guard var run = loadRun(for: assetIdentifier) else { return (nil, truth) }

        // Rulings are matched onto the run by time, so they survive the attempt ids
        // having been regenerated.
        run.attempts = GroundTruthMatcher.apply(truth.shots, to: run.attempts)

        return (run, truth)
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
