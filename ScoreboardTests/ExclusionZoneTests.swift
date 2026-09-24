//
//  ExclusionZoneTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 24/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A bin in the bottom-left corner of the frame, in Vision space (origin bottom-left).
private let bin = ExclusionZone(rect: CGRect(x: 0.05, y: 0.05, width: 0.15, height: 0.2))

/// A ball box of the usual size, centred on a point.
private func ball(at centre: CGPoint, radius: CGFloat = 0.02) -> CGRect {
    CGRect(
        x: centre.x - radius,
        y: centre.y - radius,
        width: radius * 2,
        height: radius * 2
    )
}

// MARK: - What a zone rejects

@Test("A sighting inside a blocked area is rejected")
func sightingInsideIsExcluded() {
    #expect(bin.excludes(boundingBox: ball(at: CGPoint(x: 0.1, y: 0.1))))
}

@Test("A sighting elsewhere is untouched")
func sightingOutsideIsKept() {
    #expect(bin.excludes(boundingBox: ball(at: CGPoint(x: 0.5, y: 0.6))) == false)
}

@Test("A ball passing in front of a blocked area still counts")
func overlappingBallIsKept() {
    // Centre just outside the zone's right edge, but the box clips into it. Judging on
    // overlap would punch a hole in the middle of a real trajectory.
    let clipping = ball(at: CGPoint(x: 0.215, y: 0.15), radius: 0.03)

    #expect(clipping.intersects(bin.rect))
    #expect(bin.excludes(boundingBox: clipping) == false)
}

@Test("Any one zone is enough to reject a sighting")
func anyZoneExcludes() {
    let sign = ExclusionZone(rect: CGRect(x: 0.8, y: 0.7, width: 0.15, height: 0.15))
    let zones = [bin, sign]

    #expect(zones.exclude(boundingBox: ball(at: CGPoint(x: 0.85, y: 0.75))))
    #expect(zones.exclude(boundingBox: ball(at: CGPoint(x: 0.1, y: 0.1))))
    #expect(zones.exclude(boundingBox: ball(at: CGPoint(x: 0.5, y: 0.5))) == false)
}

@Test("No zones means nothing is rejected")
func emptyZonesKeepEverything() {
    #expect([ExclusionZone]().exclude(boundingBox: ball(at: CGPoint(x: 0.1, y: 0.1))) == false)
}

// MARK: - Fitting a drawn rect

@Test("A zone drawn past the edge is pulled back into frame")
func zoneIsClampedToFrame() {
    let fitted = ExclusionZone.normalised(CGRect(x: 0.9, y: 0.9, width: 0.4, height: 0.4))

    #expect(fitted.maxX <= 1.0001)
    #expect(fitted.maxY <= 1.0001)
    #expect(fitted.minX >= 0)
}

@Test("A backwards drag still gives an upright zone")
func invertedDragIsRighted() {
    let fitted = ExclusionZone.normalised(CGRect(x: 0.6, y: 0.6, width: -0.2, height: -0.3))

    #expect(fitted.width > 0)
    #expect(fitted.height > 0)
    #expect(abs(fitted.minX - 0.4) < 0.0001)
}

@Test("A zone too small to see is grown to the minimum")
func tinyZoneIsGrown() {
    let fitted = ExclusionZone.normalised(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))

    #expect(fitted.width >= ExclusionZone.minimumSide)
    #expect(fitted.height >= ExclusionZone.minimumSide)
}

@Test("Overlapping zones are kept apart, unlike re-analysis sections")
func zonesAreNotMerged() {
    let zones = [ExclusionZone]()
        .adding(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        .adding(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))

    #expect(zones.count == 2)
}

// MARK: - Enforcement

@MainActor
@Test("A blocked sighting never reaches the shot detector")
func trackerDropsExcludedSightings() {
    let tracker = ShotTracker()
    tracker.exclusionZones = [bin]

    var snapshots: [GameSnapshot] = []
    tracker.onSnapshot = { snapshots.append($0) }

    tracker.beginFrame(1, timeSeconds: 0)
    tracker.ingestBall(boundingBox: ball(at: CGPoint(x: 0.1, y: 0.1)), confidence: 0.9, frameID: 1)

    tracker.beginFrame(2, timeSeconds: 0.03)
    tracker.ingestBall(boundingBox: ball(at: CGPoint(x: 0.5, y: 0.5)), confidence: 0.9, frameID: 2)

    tracker.beginFrame(3, timeSeconds: 0.06)

    // Only the sighting outside the zone made it into the history.
    let history = snapshots.last?.ballHistory ?? []
    #expect(history.count == 1)
    #expect(history.first.map { abs($0.center.x - 0.5) < 0.0001 } == true)
}

// MARK: - Persistence

@Test("Blocked areas are stored with the user's other corrections")
func exclusionsRoundTrip() throws {
    var document = GroundTruthDocument(assetIdentifier: "asset-1")
    document.exclusions = [bin]
    document.shots = [GroundTruthEntry(timeSeconds: 12, verdict: .made)]

    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(GroundTruthDocument.self, from: data)

    #expect(decoded.exclusions == [bin])
    #expect(decoded.shots.count == 1)
}

@Test("A truth file written before blocked areas existed still loads")
func legacyTruthDocumentStillDecodes() throws {
    // Exactly what the app wrote before this feature: no `exclusions` key at all. The
    // synthesised decoder would reject this, taking every stored ruling with it.
    let legacy = """
    {
        "version": 1,
        "assetIdentifier": "asset-1",
        "shots": [
            {
                "id": "6B4C1F1E-0000-4000-8000-000000000001",
                "timeSeconds": 12,
                "verdict": "made",
                "recordedAt": 780000000
            }
        ]
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(GroundTruthDocument.self, from: legacy)

    #expect(decoded.shots.count == 1)
    #expect(decoded.shots.first?.verdict == .made)
    #expect(decoded.exclusions.isEmpty)
    #expect(decoded.rim == nil)
}
