//
//  PlayerPositionsTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 23/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

private func box(_ x: CGFloat) -> CGRect {
    CGRect(x: x - 0.04, y: 0.2, width: 0.08, height: 0.25)
}

private func track(_ id: Int, at x: CGFloat, seen: Int, coasting: Bool = false) -> PlayerTrack {
    PlayerTrack(
        id: id,
        box: box(x),
        velocity: .zero,
        state: coasting ? .coasting : .confirmed,
        confidence: 0.9,
        firstFrame: 0,
        lastSeenFrame: seen,
        hits: 2
    )
}

/// Track 1 moving right by 0.03 every detection pass, on frames 3, 6, 9, ... at 30 fps.
private func moving(passes: Int) -> PlayerPositionRecord {
    var record = PlayerPositionRecord()
    for pass in 1...passes {
        let frame = pass * 3
        record.record(frameID: frame, time: Double(frame) / 30, tracks: [track(1, at: 0.2 + 0.03 * CGFloat(pass), seen: frame)])
    }
    return record
}

@Test("Positions are recorded only on frames where a track was matched")
func recordsOnlyDetectionFrames() {
    var record = PlayerPositionRecord()

    record.record(frameID: 3, time: 0.1, tracks: [track(1, at: 0.3, seen: 3)])
    // In between passes every box is a prediction.
    record.record(frameID: 4, time: 0.133, tracks: [track(1, at: 0.31, seen: 3)])
    // No time, nothing to place it by.
    record.record(frameID: 6, time: nil, tracks: [track(1, at: 0.32, seen: 6)])

    #expect(record.frames.map(\.frameID) == [3])
}

@Test("Between recorded frames a player slides from one to the next")
func slidesBetweenEntries() throws {
    let record = moving(passes: 4)

    // Halfway between frame 6 (x 0.26) and frame 9 (x 0.29).
    let placed = try #require(record.positions(atTime: 7.5 / 30).first)

    #expect(abs(placed.box.midX - 0.275) < 1e-6)
    #expect(placed.frameID == 6)
}

@Test("A player isn't drawn long after they were last recorded")
func gapEndsAPlayer() {
    let record = moving(passes: 4)

    #expect(record.positions(atTime: 12.0 / 30 + 0.1).count == 1)
    #expect(record.positions(atTime: 12.0 / 30 + 0.5).isEmpty)
    // The first entry is at 0.1 s: just before it they're about to appear, well before
    // it they aren't there yet.
    #expect(record.positions(atTime: 0).count == 1)
    #expect(record.positions(atTime: -0.3).isEmpty)
}

@Test("A coasting box is marked as a guess")
func coastingIsKept() throws {
    var record = PlayerPositionRecord()
    record.record(
        frameID: 3,
        time: 0.1,
        tracks: [track(1, at: 0.3, seen: 3), track(2, at: 0.7, seen: 1, coasting: true)]
    )

    let placed = record.positions(atTime: 0.1)
    #expect(placed.first { $0.trackID == 2 }?.coasting == true)
    #expect(placed.first { $0.trackID == 1 }?.coasting == false)
}

@Test("Positions survive a save and load, compressed beside the run")
func positionsRoundTripThroughTheStore() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let record = moving(passes: 200)
    let runID = UUID()
    try store.savePositions(record, for: "asset", runID: runID)

    #expect(store.loadPositions(for: "asset", runID: runID) == record)
    #expect(store.loadPositions(for: "asset", runID: UUID()) == nil)

    // Compression earns its keep.
    let json = try JSONEncoder().encode(record)
    let files = try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))
    let saved = try #require(files.first { $0.hasSuffix(".positions.lzfse") })
    let size = try FileManager.default.attributesOfItem(atPath: root.appending(path: saved).path(percentEncoded: false))[.size] as? Int
    #expect((size ?? .max) < json.count / 2)
}

@Test("Deleting a run deletes its positions")
func deletingARunDeletesPositions() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ShotStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let run = AnalysisRun(assetIdentifier: "asset", configuration: RunConfiguration(), attempts: [])
    try store.saveRun(run)
    try store.savePositions(moving(passes: 5), for: "asset", runID: run.id)

    try store.deleteRun(run.id, for: "asset")

    #expect(store.loadPositions(for: "asset", runID: run.id) == nil)
}

@Test("Boxes are saved with short keys and rounded numbers")
func entriesAreCompact() throws {
    var record = PlayerPositionRecord()
    var unrounded = track(7, at: 0.3, seen: 3)
    unrounded.box = CGRect(x: 0.123456789, y: 0.2, width: 0.08, height: 0.25)
    record.record(frameID: 3, time: 0.1, tracks: [unrounded])

    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)

    #expect(json.contains("\"t\":7"))
    #expect(json.contains("0.1235"))
    #expect(!json.contains("\"c\""))
}
