//
//  ReanalysisSectionTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 20/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

private let clip: Double = 90

// MARK: - Fitting a range to the clip

@Test("A section is clamped to the clip it was marked on")
func sectionStaysInsideTheClip() {
    let fitted = ReanalysisSection.normalised((-4)...(clip + 20), clipDuration: clip)

    #expect(fitted.lowerBound == 0)
    #expect(fitted.upperBound == clip)
}

@Test("A range dragged backwards still reads start to end")
func invertedRangeIsRighted() {
    let fitted = ReanalysisSection.normalised(40...20, clipDuration: clip)

    #expect(fitted.lowerBound == 20)
    #expect(fitted.upperBound == 40)
}

@Test("A too-short mark is grown rather than rejected")
func shortSectionIsGrown() {
    let fitted = ReanalysisSection.normalised(10...10.1, clipDuration: clip)

    #expect(fitted.upperBound - fitted.lowerBound >= ReanalysisSection.minimumDuration)
}

@Test("A short mark at the very end of the clip grows backwards")
func shortSectionAtTheEndGrowsBackwards() {
    let fitted = ReanalysisSection.normalised(clip...clip, clipDuration: clip)

    #expect(fitted.upperBound == clip)
    #expect(fitted.lowerBound <= clip - ReanalysisSection.minimumDuration)
}

// MARK: - Merging

@Test("Overlapping marks become one section")
func overlappingMarksMerge() {
    let sections = [ReanalysisSection]()
        .marking(10...20, clipDuration: clip)
        .marking(15...30, clipDuration: clip)

    #expect(sections.count == 1)
    #expect(sections[0].startTime == 10)
    #expect(sections[0].endTime == 30)
}

@Test("Marks that only touch at the edge also merge")
func touchingMarksMerge() {
    let sections = [ReanalysisSection]()
        .marking(10...20, clipDuration: clip)
        .marking(20...25, clipDuration: clip)

    #expect(sections.count == 1)
    #expect(sections[0].endTime == 25)
}

@Test("A merge keeps the oldest identity, so the list doesn't reshuffle")
func mergeKeepsOldestIdentity() {
    let first = [ReanalysisSection]().marking(10...20, clipDuration: clip)
    let original = first[0]

    let merged = first.marking(18...24, clipDuration: clip)

    #expect(merged[0].id == original.id)
    #expect(merged[0].createdAt == original.createdAt)
}

@Test("A mark swallowed by an existing one changes nothing")
func containedMarkIsAbsorbed() {
    let sections = [ReanalysisSection]()
        .marking(10...40, clipDuration: clip)
        .marking(20...25, clipDuration: clip)

    #expect(sections.count == 1)
    #expect(sections[0].range == 10...40)
}

@Test("Separate marks stay separate, in playing order")
func disjointMarksAreKeptApart() {
    let sections = [ReanalysisSection]()
        .marking(50...60, clipDuration: clip)
        .marking(10...20, clipDuration: clip)

    #expect(sections.count == 2)
    #expect(sections.map(\.startTime) == [10, 50])
}

@Test("One mark can bridge two that were separate")
func bridgingMarkMergesBoth() {
    let sections = [ReanalysisSection]()
        .marking(10...20, clipDuration: clip)
        .marking(40...50, clipDuration: clip)
        .marking(18...42, clipDuration: clip)

    #expect(sections.count == 1)
    #expect(sections[0].range == 10...50)
}

// MARK: - The plan

@Test("Marks survive a round trip through JSON")
func planRoundTrips() throws {
    var plan = ReanalysisPlan(assetIdentifier: "asset-1")
    plan.mark(10...20, clipDuration: clip)
    plan.mark(60...70, clipDuration: clip)

    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(ReanalysisPlan.self, from: data)

    #expect(decoded.sections.map(\.range) == [10...20, 60...70])
    #expect(decoded.assetIdentifier == "asset-1")
}

@Test("Removing a section leaves the others alone")
func removingASection() {
    var plan = ReanalysisPlan(assetIdentifier: "asset-1")
    plan.mark(10...20, clipDuration: clip)
    plan.mark(60...70, clipDuration: clip)

    plan.remove(plan.sections[0].id)

    #expect(plan.sections.count == 1)
    #expect(plan.sections[0].startTime == 60)
}

@Test("The plan knows how much footage is queued, and what covers a moment")
func planTotalsAndLookup() {
    var plan = ReanalysisPlan(assetIdentifier: "asset-1")
    plan.mark(10...20, clipDuration: clip)
    plan.mark(60...70, clipDuration: clip)

    #expect(plan.totalDuration == 20)
    #expect(plan.section(at: 65)?.startTime == 60)
    #expect(plan.section(at: 35) == nil)
}

@Test("Marks are stored per video and read back by identifier")
func planPersistsThroughTheStore() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(store.loadPlan(for: "asset-1").sections.isEmpty)

    var plan = ReanalysisPlan(assetIdentifier: "asset-1")
    plan.mark(12...18, clipDuration: clip)
    try store.savePlan(plan)

    #expect(store.loadPlan(for: "asset-1").sections.count == 1)
    // A different video's marks are its own.
    #expect(store.loadPlan(for: "asset-2").sections.isEmpty)
}
