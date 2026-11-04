//
//  ScenePauseTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 04/11/2026.
//

import Testing
import Foundation
@testable import Scoreboard

@Test("A running pass is held when the app goes away")
func runningPassPausesWhenAway() {
    #expect(ScenePause.action(isActive: false, playback: .resume, reason: nil) == .pause)
}

@Test("A pass the app held picks up again on return")
func systemPauseResumesOnReturn() {
    #expect(ScenePause.action(isActive: true, playback: .pause, reason: .systemTriggered) == .resume)
}

@Test("A pass the user paused stays paused through leaving and coming back")
func userPauseSurvivesLeaving() {
    // Leaving must not relabel the user's pause as one the app made.
    #expect(ScenePause.action(isActive: false, playback: .pause, reason: .userInitiated) == .none)
    #expect(ScenePause.action(isActive: true, playback: .pause, reason: .userInitiated) == .none)
}

@Test("A finished clip is never resumed")
func endOfClipNeverResumes() {
    // Resuming would go round the loop on an empty reader and end the shot stream again.
    #expect(ScenePause.action(isActive: true, playback: .pause, reason: .endOfClip) == .none)
}

@Test("A pass that hasn't started, or whose reader failed, isn't started by coming back")
func unexplainedPauseNeverResumes() {
    #expect(ScenePause.action(isActive: true, playback: .pause, reason: nil) == .none)
}
