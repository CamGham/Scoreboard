//
//  ExclusionZoneEditorTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 24/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

// MARK: - Spaces

@Test("Image space and Vision space are a y-flip apart")
func imageToVisionFlipsY() {
    // A box against the TOP of the picture in image space is against the TOP in Vision
    // space too — which is a high y there, not a low one.
    let atTop = CGRect(x: 0.1, y: 0, width: 0.2, height: 0.25)

    let vision = ExclusionZoneEditor.visionRect(fromImage: atTop)

    #expect(vision.minX == 0.1)
    #expect(abs(vision.maxY - 1) < 0.0001)
    #expect(abs(vision.minY - 0.75) < 0.0001)
}

@Test("A box at the bottom of the picture lands at the bottom in Vision space")
func bottomStaysBottom() {
    let atBottom = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.2)

    let vision = ExclusionZoneEditor.visionRect(fromImage: atBottom)

    #expect(abs(vision.minY) < 0.0001)
}

@Test("Converting there and back changes nothing")
func conversionRoundTrips() {
    let original = CGRect(x: 0.23, y: 0.41, width: 0.17, height: 0.29)

    let there = ExclusionZoneEditor.visionRect(fromImage: original)
    let back = ExclusionZoneEditor.imageRect(fromVision: there)

    #expect(abs(back.minX - original.minX) < 0.0001)
    #expect(abs(back.minY - original.minY) < 0.0001)
    #expect(abs(back.width - original.width) < 0.0001)
    #expect(abs(back.height - original.height) < 0.0001)
}

@Test("A stored zone drawn at the top of the frame comes back at the top")
func zoneSurvivesTheEditorRoundTrip() {
    // The bug this guards: a zone that looks right in the editor but blocks the mirror
    // image of it during analysis.
    let drawnNearTop = CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.15)

    let stored = ExclusionZoneEditor.visionRect(fromImage: drawnNearTop)
    let zone = ExclusionZone(rect: stored)

    // A ball sighting in the top of the frame is high in Vision space.
    let highInFrame = CGRect(x: 0.48, y: 0.85, width: 0.04, height: 0.04)
    #expect(zone.excludes(boundingBox: highInFrame))

    // ...and one low in the frame is not touched by it.
    let lowInFrame = CGRect(x: 0.48, y: 0.12, width: 0.04, height: 0.04)
    #expect(zone.excludes(boundingBox: lowInFrame) == false)
}

// MARK: - Hit-testing

@Test("A drag starting on a zone edits that zone")
func dragOnZoneFindsIt() {
    let boxes = [
        CGRect(x: 10, y: 10, width: 100, height: 80),
        CGRect(x: 200, y: 150, width: 60, height: 60)
    ]

    #expect(ExclusionZoneEditor.index(at: CGPoint(x: 50, y: 40), in: boxes) == 0)
    #expect(ExclusionZoneEditor.index(at: CGPoint(x: 220, y: 170), in: boxes) == 1)
}

@Test("A drag starting on empty space draws a new zone")
func dragOnEmptySpaceFindsNothing() {
    let boxes = [CGRect(x: 10, y: 10, width: 100, height: 80)]

    #expect(ExclusionZoneEditor.index(at: CGPoint(x: 400, y: 400), in: boxes) == nil)
}

@Test("Slop makes a zone's edge reachable, since that is where the handles are")
func slopCatchesTheEdge() {
    let boxes = [CGRect(x: 10, y: 10, width: 100, height: 80)]
    let justOutside = CGPoint(x: 10, y: 100)

    #expect(ExclusionZoneEditor.index(at: justOutside, in: boxes) == nil)
    #expect(ExclusionZoneEditor.index(at: justOutside, in: boxes, slop: 24) == 0)
}

@Test("Where zones overlap, the one on top is the one grabbed")
func topmostZoneWins() {
    let boxes = [
        CGRect(x: 0, y: 0, width: 200, height: 200),
        CGRect(x: 50, y: 50, width: 100, height: 100)
    ]

    #expect(ExclusionZoneEditor.index(at: CGPoint(x: 100, y: 100), in: boxes) == 1)
}

// MARK: - Drawing

@Test("A tap is not a zone")
func tapIsNotAZone() {
    let tap = CGRect(x: 100, y: 100, width: 1, height: 2)

    #expect(ExclusionZoneEditor.isBigEnough(tap, minimumSide: 8) == false)
}

@Test("A real drag is a zone, in any direction")
func dragIsAZone() {
    let downRight = CGRect(x: 100, y: 100, width: 60, height: 40)
    let upLeft = CGRect(x: 160, y: 140, width: -60, height: -40)

    #expect(ExclusionZoneEditor.isBigEnough(downRight, minimumSide: 8))
    #expect(ExclusionZoneEditor.isBigEnough(upLeft, minimumSide: 8))
}
