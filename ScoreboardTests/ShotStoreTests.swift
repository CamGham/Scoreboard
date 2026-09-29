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

// MARK: - Recording dates

private func summary(_ id: String, analysed: TimeInterval, captured: TimeInterval?) -> SavedGameSummary {
    SavedGameSummary(
        assetIdentifier: id,
        analysedAt: Date(timeIntervalSince1970: analysed),
        capturedAt: captured.map { Date(timeIntervalSince1970: $0) },
        attempts: 0, makes: 0, reviewed: 0, agreed: 0
    )
}

@Test("Sorting by recording date puts games without one last")
func captureSortOrdersUndatedLast() {
    let games = [
        summary("undated-old", analysed: 100, captured: nil),
        summary("recorded-early", analysed: 900, captured: 10),
        summary("undated-new", analysed: 800, captured: nil),
        summary("recorded-late", analysed: 200, captured: 50)
    ]

    #expect(SavedGameSort.captured.sorted(games).map(\.assetIdentifier) == [
        "recorded-late", "recorded-early", "undated-new", "undated-old"
    ])
    #expect(SavedGameSort.analysed.sorted(games).map(\.assetIdentifier) == [
        "recorded-early", "undated-new", "recorded-late", "undated-old"
    ])
}

@Test("Refreshing a summary keeps the recording date")
func refreshKeepsCaptureDate() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let recorded = Date(timeIntervalSince1970: 1_000)
    try store.refreshSummary(for: photosIdentifier, attempts: [], capturedAt: recorded)

    // A correction in the detail view rewrites the summary without knowing the date.
    try store.refreshSummary(for: photosIdentifier, attempts: [])

    #expect(store.loadSummary(for: photosIdentifier)?.capturedAt == recorded)
}

@Test("Summaries saved before recording dates still load")
func legacySummaryDecodes() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    try store.saveSummary(summary(photosIdentifier, analysed: 100, captured: nil))

    let loaded = try #require(store.loadSummary(for: photosIdentifier))
    #expect(loaded.capturedAt == nil)
}
