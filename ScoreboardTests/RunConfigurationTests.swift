//
//  RunConfigurationTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 23/10/2026.
//

import Testing
import Foundation
@testable import Scoreboard

@Test("Every part of the pipeline's settings survives a save and load with the run")
func runConfigurationRoundTrips() throws {
    var configuration = RunConfiguration()
    configuration.players.maxCoastFrames = 45
    configuration.players.kalman.velocityNoiseWeight = 1.0 / 80
    configuration.possession.sightingsToSwitch = 4
    configuration.shooter.takeOffWindowFrames = 20
    configuration.identity.clearMargin = 0.2
    configuration.identity.appearance.clearance = 0.15
    configuration.identity.resolver.nearestLooks = 5
    configuration.appearanceSampler.darkLuma = 30
    configuration.vision.rimSampleInterval = 60
    configuration.rimPreflight.sampleCount = 20

    let decoded = try JSONDecoder().decode(RunConfiguration.self, from: JSONEncoder().encode(configuration))

    #expect(decoded == configuration)
}

@Test("A run saved before these settings were recorded loads with today's defaults")
func olderRunConfigurationLoads() throws {
    let json = #"{"shotDetector":{},"ballROI":{},"fullFrameBallConfidence":0.45,"croppedBallConfidence":0.25,"modelIdentifier":"best5s","rimSource":"detected","appVersion":"1.0 (1)"}"#

    let decoded = try JSONDecoder().decode(RunConfiguration.self, from: Data(json.utf8))

    #expect(decoded.players == PlayerTracker.Config())
    #expect(decoded.identity == IdentityTracker.Config())
    #expect(decoded.appearanceSampler == AppearanceSampler.Config())
    #expect(decoded.modelIdentifier == "best5s")
}

@Test("A setting saved partway — only some fields present — keeps the rest at their defaults")
func partialSettingsLoad() throws {
    let json = #"{"reachSlack":0.2,"appearance":{"clearance":0.3}}"#

    let decoded = try JSONDecoder().decode(IdentityTracker.Config.self, from: Data(json.utf8))

    #expect(decoded.reachSlack == 0.2)
    #expect(decoded.appearance.clearance == 0.3)
    #expect(decoded.appearance.samplesBeforeComparing == AppearanceSeparation.Config().samplesBeforeComparing)
    #expect(decoded.clearMargin == IdentityTracker.Config().clearMargin)
}

@Test("A changed setting shows up when two runs are compared")
func changedSettingIsDescribed() {
    let before = RunConfiguration(appVersion: "1")
    var after = before
    after.identity.clearMargin = 0.25
    after.players.kalman.sizeNoiseWeight = 0.05

    let changes = after.differences(from: before)

    #expect(changes.contains("identity.clearMargin 0.15 → 0.25"))
    #expect(changes.contains { $0.hasPrefix("players.kalman.sizeNoiseWeight ") })
    #expect(RunConfiguration(appVersion: "1").differences(from: before).isEmpty)
}

@Test("The sampler's colour thresholds come from its config")
func samplerUsesItsConfig() {
    let standard = AppearanceSampler()
    var darker = AppearanceSampler.Config()
    darker.darkLuma = 40

    // A dim but clearly blue pixel.
    #expect(standard.bin(luma: 30, cb: 200, cr: 100) >= 3)
    #expect(AppearanceSampler(config: darker).bin(luma: 30, cb: 200, cr: 100) == 0)
}

@Test("The box filter's noise comes from its config")
func kalmanUsesItsConfig() {
    let box = CGRect(x: 0.46, y: 0.4, width: 0.08, height: 0.25)
    var restless = BoxKalmanFilter.Config()
    restless.positionNoiseWeight = 1.0 / 2

    var standard = BoxKalmanFilter(box: box)
    var following = BoxKalmanFilter(box: box, config: restless)
    let moved = box.offsetBy(dx: 0.05, dy: 0)
    standard.predict(frames: 3)
    following.predict(frames: 3)
    standard.update(with: moved)
    following.update(with: moved)

    // A box allowed to wander more is less sure of its prediction, so it follows the
    // new detection further.
    #expect(following.box.midX > standard.box.midX)
}
