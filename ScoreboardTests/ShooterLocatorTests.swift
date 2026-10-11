//
//  ShooterLocatorTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 11/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

/// A held frame for `player`, whose box bottom sits at `bottom`.
private func held(_ frame: Int, by player: Int, bottom: CGFloat = 0.30, x: CGFloat = 0.3) -> PossessionFrame {
    PossessionFrame(
        frameID: frame,
        timeSeconds: Double(frame) / 30,
        playerID: player,
        box: CGRect(x: x - 0.04, y: bottom, width: 0.08, height: 0.25),
        ballSeen: true
    )
}

private func record(_ frames: [PossessionFrame]) -> PossessionRecord {
    PossessionRecord(config: PossessionTracker.Config(), frames: frames)
}

// MARK: - Who and when

@Test("The shooter is whoever last held the ball before the attempt opened")
func shooterIsLastHolder() throws {
    let possession = record((1...20).map { held($0, by: 2) })

    let shooter = try #require(ShooterLocator.locate(in: possession, openedAt: 28))
    #expect(shooter.playerID == 2)
    #expect(shooter.releaseFrame == 20)
    #expect(shooter.releaseTime == 20.0 / 30)
}

@Test("After a pass, the receiver is the shooter")
func receiverShoots() throws {
    let possession = record((1...10).map { held($0, by: 1) } + (14...24).map { held($0, by: 2, x: 0.6) })

    let shooter = try #require(ShooterLocator.locate(in: possession, openedAt: 30))
    #expect(shooter.playerID == 2)
}

@Test("A release too long before the attempt opened gives no shooter")
func staleReleaseHasNoShooter() {
    let possession = record((1...20).map { held($0, by: 2) })
    let limit = ShooterLocator.Config().maxReleaseAgeFrames

    #expect(ShooterLocator.locate(in: possession, openedAt: 20 + limit) != nil)
    #expect(ShooterLocator.locate(in: possession, openedAt: 20 + limit + 1) == nil)
}

@Test("Nobody having held the ball gives no shooter")
func noPossessionNoShooter() {
    #expect(ShooterLocator.locate(in: record([]), openedAt: 30) == nil)
}

// MARK: - Where from

@Test("Take-off is the last moment the feet were lowest before release")
func takeOffIsLowestBeforeRelease() throws {
    // Standing until frame 16, then rising through the jump to release at frame 20.
    let standing = (8...16).map { held($0, by: 2, bottom: 0.30) }
    let jumping = [17, 18, 19, 20].enumerated().map { step, frame in
        held(frame, by: 2, bottom: 0.30 + CGFloat(step + 1) * 0.02)
    }

    let shooter = try #require(ShooterLocator.locate(in: record(standing + jumping), openedAt: 26))
    #expect(shooter.takeOffFrame == 16)
    #expect(abs(shooter.takeOffPoint.x - 0.3) < 1e-9)
    #expect(abs(shooter.takeOffPoint.y - 0.30) < 1e-9)
    #expect(shooter.releaseBox.minY > shooter.takeOffPoint.y)
}

@Test("Take-off only looks back half a second")
func takeOffWindowIsBounded() throws {
    let window = ShooterLocator.Config().takeOffWindowFrames

    // Much lower long before the shot, then steady through the run-up.
    let early = [held(1, by: 2, bottom: 0.10)]
    let runUp = (2...40).map { held($0, by: 2, bottom: 0.30) }

    let shooter = try #require(ShooterLocator.locate(in: record(early + runUp), openedAt: 45))
    #expect(shooter.takeOffFrame >= 40 - window)
    #expect(abs(shooter.takeOffPoint.y - 0.30) < 1e-9)
}

@Test("Take-off never uses the passer's frames")
func takeOffIgnoresPasser() throws {
    // The passer's box sits lower, right up to the catch-and-shoot.
    let passer = (1...12).map { held($0, by: 1, bottom: 0.10, x: 0.2) }
    let shooterFrames = (13...18).map { held($0, by: 2, bottom: 0.30, x: 0.6) }

    let shooter = try #require(ShooterLocator.locate(in: record(passer + shooterFrames), openedAt: 24))
    #expect(shooter.playerID == 2)
    #expect(abs(shooter.takeOffPoint.x - 0.6) < 1e-9)
    #expect(abs(shooter.takeOffPoint.y - 0.30) < 1e-9)
}

// MARK: - Through the shot tracker

/// A shot from (0.15, 0.35) that drops through the rim plane at x = 0.5.
private func shotArc(startFrame: Int, rim: HoopGeometry) -> [CGPoint] {
    let fromX = 0.15, fromY = 0.35, peakY = 0.88, frames = 30
    let planeY = Double(rim.center.y)
    let ratio = (planeY - fromY) / (peakY - fromY)
    let sCross = (1.0 + (1.0 - ratio).squareRoot()) / 2.0
    let landX = fromX + (0.5 - fromX) / sCross

    return (0...frames).map { step in
        let s = Double(step) / Double(frames)
        return CGPoint(x: fromX + (landX - fromX) * s, y: fromY + 4 * (peakY - fromY) * s * (1 - s))
    }
}

@MainActor
@Test("The shooter found as an attempt opens is still on it when it resolves")
func shooterTravelsWithAttempt() throws {
    let rim = HoopGeometry(center: CGPoint(x: 0.5, y: 0.70), verticalRadius: 0.012, horizontalRadius: 0.045)
    let tracker = ShotTracker()
    tracker.setUserRim(rim)

    let sighting = ShooterSighting(
        playerID: 7, releaseFrame: 0, releaseTime: 0, releaseBox: .zero,
        takeOffFrame: 0, takeOffTime: 0, takeOffPoint: CGPoint(x: 0.15, y: 0.1)
    )
    var lookups = 0
    tracker.locateShooter = { _ in
        lookups += 1
        return sighting
    }

    var started: ShotAttempt?
    var resolved: ShotAttempt?
    tracker.onEvent = { event in
        switch event {
        case .attemptStarted(let attempt): started = attempt
        case .attemptResolved(let attempt): resolved = attempt
        default: break
        }
    }

    let radius: CGFloat = 0.022
    for (offset, centre) in shotArc(startFrame: 1, rim: rim).enumerated() {
        let frame = offset + 1
        tracker.beginFrame(frame, timeSeconds: Double(frame) / 30)
        tracker.ingestBall(
            boundingBox: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2),
            confidence: 0.9,
            frameID: frame
        )
    }
    tracker.endOfStream(atFrame: 40)

    #expect(lookups == 1)
    #expect(started?.shooter == sighting)
    #expect(resolved?.shooter == sighting)
}
