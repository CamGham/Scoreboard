//
//  SnapshotStore.swift
//  Scoreboard
//
//  Created by Cam Graham on 10/11/2026.
//

import Foundation

/// Keeps the one analysis in progress — see `AnalysisSnapshot`.
///
/// One file, so there is only ever one: saving another replaces it. It sits beside the
/// videos folder rather than in it, since everything in that folder is read as a video.
/// Compressed, because most of it is the record of where every player was.
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
    private let fileManager: FileManager

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let url {
            self.url = url
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = support.appending(path: "Scoreboard/in-progress.snapshot")
        }
    }

    func save(_ snapshot: AnalysisSnapshot) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let json = try SnapshotCoding.encoder().encode(snapshot)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data

        // Atomic, so a write cut short as the app is suspended can't leave half a file
        // where the last good snapshot was.
        try compressed.write(to: url, options: .atomic)
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
    }

    private struct Header: Decodable {
        var formatVersion: Int?
        var assetIdentifier: String?
    }
}
