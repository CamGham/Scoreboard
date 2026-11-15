//
//  PlayerDetectionStatsTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 02/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A player-sized box with its bottom-left corner at a point.
private func player(at x: CGFloat, _ y: CGFloat, confidence: Float = 0.9) -> PlayerDetection {
    PlayerDetection(
        boundingBox: CGRect(x: x, y: y, width: 0.08, height: 0.25),
        confidence: confidence
    )
}

// MARK: - Counting

@Test("Only players at the tracker's floor are counted")
func countsAcceptedPlayersOnly() {
    var stats = PlayerDetectionStats()
    stats.record(
        frameID: 1,
        detections: [player(at: 0.1, 0.1), player(at: 0.5, 0.1, confidence: 0.45)],
        previous: nil,
        trackedPlayers: 2,
        source: .sweep
    )

    #expect(stats.acceptedDetections == 1)
    #expect(stats.countHistogram[1] == 1)
    #expect(stats.meanPlayersTracked == 2)
}

@Test("Every counted box lands in a confidence bucket")
func bucketsConfidence() {
    var stats = PlayerDetectionStats()
    stats.record(
        frameID: 1,
        detections: [
            player(at: 0.1, 0.1, confidence: 0.3),
            player(at: 0.3, 0.1, confidence: 0.5),
            player(at: 0.5, 0.1, confidence: 0.6),
            player(at: 0.7, 0.1, confidence: 0.95),
        ],
        previous: nil,
        trackedPlayers: 0,
        source: .pass
    )

    #expect(stats.confidenceBuckets == [1, 1, 2])
    #expect(stats.belowAcceptedShare == 0.5)
}

@Test("A crowded frame is counted in the top bin")
func crowdedFrameIsCapped() {
    let crowd = (0..<14).map { player(at: CGFloat($0) * 0.07, 0.1) }

    var stats = PlayerDetectionStats()
    stats.record(frameID: 1, detections: crowd, previous: nil, trackedPlayers: 6, source: .pass)

    #expect(stats.countHistogram.last == 1)
    #expect(stats.acceptedDetections == 14)
}

@Test("A frame with no players counts towards the empty rate")
func emptyFrame() {
    var stats = PlayerDetectionStats()
    stats.record(frameID: 1, detections: [], previous: nil, trackedPlayers: 0, source: .sweep)
    stats.record(frameID: 2, detections: [player(at: 0.1, 0.1)], previous: nil, trackedPlayers: 0, source: .sweep)

    #expect(stats.emptyFrameRate == 0.5)
}

// MARK: - Persistence

@Test("A player who barely moved between samples persists")
func movedPlayerPersists() {
    var stats = PlayerDetectionStats()
    let first = stats.record(
        frameID: 3, detections: [player(at: 0.40, 0.2)],
        previous: nil, trackedPlayers: 1, source: .pass
    )
    stats.record(
        frameID: 6, detections: [player(at: 0.42, 0.2)],
        previous: first, trackedPlayers: 1, source: .pass
    )

    #expect(stats.pairedFrames == 1)
    #expect(stats.persistenceRate == 1)
    #expect(stats.meanCountChange == 0)
}

@Test("A player appearing out of nowhere doesn't persist, and the count change is recorded")
func newPlayerDoesNotPersist() {
    var stats = PlayerDetectionStats()
    let first = stats.record(
        frameID: 3, detections: [player(at: 0.1, 0.2)],
        previous: nil, trackedPlayers: 1, source: .pass
    )
    stats.record(
        frameID: 4, detections: [player(at: 0.1, 0.2), player(at: 0.7, 0.2)],
        previous: first, trackedPlayers: 1, source: .sweep
    )

    #expect(stats.pairedDetections == 2)
    #expect(stats.persistedDetections == 1)
    #expect(stats.meanCountChange == 1)
}

@Test("Samples too far apart aren't compared")
func distantSamplesAreNotPaired() {
    var stats = PlayerDetectionStats()
    let first = stats.record(
        frameID: 3, detections: [player(at: 0.1, 0.2)],
        previous: nil, trackedPlayers: 1, source: .pass
    )
    stats.record(
        frameID: 3 + PlayerDetectionStats.maxPairGap + 1, detections: [player(at: 0.1, 0.2)],
        previous: first, trackedPlayers: 1, source: .pass
    )

    #expect(stats.pairedFrames == 0)
}

@Test("A low-confidence box in the previous sample isn't something to persist from")
func persistenceUsesAcceptedBoxesOnly() {
    var stats = PlayerDetectionStats()
    let first = stats.record(
        frameID: 1, detections: [player(at: 0.1, 0.2, confidence: 0.4)],
        previous: nil, trackedPlayers: 0, source: .sweep
    )
    stats.record(
        frameID: 2, detections: [player(at: 0.1, 0.2)],
        previous: first, trackedPlayers: 0, source: .sweep
    )

    #expect(first.boxes.isEmpty)
    #expect(stats.persistedDetections == 0)
}

// MARK: - Overlap

@Test("Overlap is 1 for the same box and 0 for disjoint ones")
func intersectionOverUnionBounds() {
    let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
    // Within rounding: `intersection` recomputes the width as maxX - minX.
    #expect(abs(box.intersectionOverUnion(with: box) - 1) < 1e-9)
    #expect(box.intersectionOverUnion(with: box.offsetBy(dx: 0.5, dy: 0)) == 0)

    // Half-width shift: overlap 0.1×0.2, union 0.3×0.2.
    let shifted = box.offsetBy(dx: 0.1, dy: 0)
    #expect(abs(box.intersectionOverUnion(with: shifted) - 1.0 / 3.0) < 1e-9)
}

// MARK: - Storage

@Test("Player stats survive a save and load")
func playerStatsRoundTrip() throws {
    var stats = PlayerDetectionStats(passInterval: 3)
    stats.record(frameID: 3, detections: [player(at: 0.1, 0.1)], previous: nil, trackedPlayers: 2, source: .pass)

    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: [],
        playerStats: stats
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.playerStats == stats)
}

@Test("A run saved before player stats existed still loads")
func runWithoutPlayerStatsLoads() throws {
    let run = AnalysisRun(
        assetIdentifier: "asset",
        configuration: RunConfiguration(shotDetector: ShotDetectorConfig()),
        attempts: []
    )

    let decoded = try JSONDecoder().decode(AnalysisRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.playerStats == nil)
}

@Test("Stats with a tracking summary survive a save and load")
func trackingSummaryRoundTrip() throws {
    var stats = PlayerDetectionStats(passInterval: 3)
    stats.tracking = .init(config: PlayerTracker.Config(), tracksConfirmed: 3, confirmedTrackFrames: 360)

    let decoded = try JSONDecoder().decode(PlayerDetectionStats.self, from: JSONEncoder().encode(stats))
    #expect(decoded == stats)
    #expect(decoded.tracking?.meanTrackLifetimeFrames == 120)
}

@Test("Stats saved by the probe, before the tracker, still load")
func probeEraStatsLoad() throws {
    // Exactly the shape the probe wrote: its own names for passes, and no tracking.
    let json = """
    {"probeInterval":3,"sampledFrames":10,"sweepSamples":4,"probeSamples":6,
     "acceptedDetections":16,"countHistogram":[0,4,6,0,0,0,0,0,0,0,0],
     "confidenceBuckets":[1,2,16],"pairedFrames":8,"pairedDetections":13,
     "persistedDetections":12,"countChangeSum":2,"trackedPlayerSum":12}
    """

    let stats = try JSONDecoder().decode(PlayerDetectionStats.self, from: Data(json.utf8))
    #expect(stats.passInterval == 3)
    #expect(stats.passSamples == 6)
    #expect(stats.tracking == nil)
    #expect(stats.meanPlayersTracked == 1.2)
}
