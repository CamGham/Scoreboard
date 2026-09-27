//
//  ShotStoreTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 27/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// Shaped like a real Photos identifier: the `/` and `-` are what get percent-encoded
/// into the directory name.
private let photosIdentifier = "9F2A1C3B-1234-4ABC-9DEF-0123456789AB/L0/001"

@Test("Deleting a video removes everything stored for it")
func deleteRemovesStoredVideo() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    try store.saveTruth(GroundTruthDocument(assetIdentifier: photosIdentifier))
    var plan = ReanalysisPlan(assetIdentifier: photosIdentifier)
    plan.mark(12...18, clipDuration: 90)
    try store.savePlan(plan)

    #expect(store.storedAssetIdentifiers() == [photosIdentifier])

    try store.delete(assetIdentifier: photosIdentifier)

    #expect(store.storedAssetIdentifiers().isEmpty)
    #expect(store.loadPlan(for: photosIdentifier).sections.isEmpty)
}
