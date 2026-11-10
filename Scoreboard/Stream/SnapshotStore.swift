//
//  SnapshotStore.swift
//  Scoreboard
//
//  Created by Cam Graham on 10/11/2026.
//

import Foundation

/// Keeps the one analysis in progress — see `AnalysisSnapshot`.
///
/// One snapshot, so there is only ever one: saving another replaces it. It sits beside
/// the videos folder rather than in it, since everything in that folder is read as a
/// video. Compressed, because most of it is the record of where every player was.
///
/// Beside it, a few hundred bytes saying what it is — `InProgressSummary` — so the
/// screens that only show the pass in progress needn't decode megabytes to do it.
struct SnapshotStore {

    /// What loading found.
    enum Loaded {
        case none
        case ready(AnalysisSnapshot)

        /// Saved by another version of the app, or unreadable. Says which video when it
        /// can, so the user can be told which pass can't be carried on.
        case incompatible(assetIdentifier: String?)
    }

    private let url: URL
    private let summaryURL: URL
    private let fileManager: FileManager

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let url {
            self.url = url
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = support.appending(path: "Scoreboard/in-progress.snapshot")
        }
        summaryURL = self.url.deletingPathExtension().appendingPathExtension("json")
    }

    func save(_ snapshot: AnalysisSnapshot) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let json = try SnapshotCoding.encoder().encode(snapshot)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data

        // Atomic, so a write cut short as the app is suspended can't leave half a file
        // where the last good snapshot was.
        try compressed.write(to: url, options: .atomic)

        // After the snapshot, so a summary never describes a snapshot that isn't there.
        try JSONEncoder().encode(InProgressSummary(snapshot)).write(to: summaryURL, options: .atomic)
    }

    /// What the pass in progress is, without reading the pass itself. Nil when there is
    /// none.
    func loadSummary() -> InProgressSummary? {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: summaryURL)
        else { return nil }
        return try? JSONDecoder().decode(InProgressSummary.self, from: data)
    }

    func load() -> Loaded {
        guard let compressed = try? Data(contentsOf: url) else { return .none }

        guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data else {
            return .incompatible(assetIdentifier: nil)
        }

        // Read the version first, from just the fields every version has, so a snapshot
        // in another shape can still say which video it was for.
        let header = try? SnapshotCoding.decoder().decode(Header.self, from: json)

        guard header?.formatVersion == AnalysisSnapshot.currentFormatVersion,
              let snapshot = try? SnapshotCoding.decoder().decode(AnalysisSnapshot.self, from: json)
        else { return .incompatible(assetIdentifier: header?.assetIdentifier) }

        return .ready(snapshot)
    }

    func delete() {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: summaryURL)
    }

    private struct Header: Decodable {
        var formatVersion: Int?
        var assetIdentifier: String?
    }
}

/// What the analysis in progress is, for showing it: which video, how far it got, what it
/// has found. Written beside the snapshot each time it is saved.
struct InProgressSummary: Codable, Equatable {
    var formatVersion: Int
    var assetIdentifier: String
    var capturedAt: Date?
    var savedAt: Date
    var analysedSeconds: Double
    var clipSeconds: Double
    var attempts: Int
    var makes: Int

    init(_ snapshot: AnalysisSnapshot) {
        let stats = ShotStats(attempts: snapshot.game.shotTimeline + snapshot.game.abandonedAttempts)
        formatVersion = snapshot.formatVersion
        assetIdentifier = snapshot.assetIdentifier
        capturedAt = snapshot.capturedAt
        savedAt = snapshot.savedAt
        analysedSeconds = snapshot.analysedSeconds
        clipSeconds = snapshot.clipSeconds
        attempts = stats.attempts
        makes = stats.makes
    }

    /// Whether this version of the app can carry it on.
    var canContinue: Bool { formatVersion == AnalysisSnapshot.currentFormatVersion }

    /// How much of the clip has been analysed, 0–1. Zero when the length isn't known.
    var fraction: Double {
        guard clipSeconds > 0 else { return 0 }
        return min(max(analysedSeconds / clipSeconds, 0), 1)
    }

    /// "33% analysed", or nothing to say when the length isn't known.
    var percentText: String? {
        guard clipSeconds > 0 else { return nil }
        return "\(Int((fraction * 100).rounded(.down)))% analysed"
    }

    /// "1:23 of 4:10 · 2:47 left", or just the time reached when the length isn't known.
    var timeText: String {
        let reached = ShotScrubber.timecode(analysedSeconds)
        guard clipSeconds > 0 else { return "\(reached) analysed" }
        let left = max(clipSeconds - analysedSeconds, 0)
        return "\(reached) of \(ShotScrubber.timecode(clipSeconds)) · \(ShotScrubber.timecode(left)) left"
    }
}
