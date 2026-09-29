//
//  AnalysisProgressTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 24/09/2026.
//

import Testing
import Foundation
@testable import Scoreboard

@Test("Progress is measured in media time against the clip's length")
func progressFraction() {
    let progress = AnalysisProgress(analysedSeconds: 30, clipSeconds: 120, elapsedSeconds: 10)

    #expect(progress.fraction == 0.25)
}

@Test("A clip of unknown length reads as no progress rather than a guess")
func unknownClipLength() {
    let progress = AnalysisProgress(analysedSeconds: 30, clipSeconds: 0, elapsedSeconds: 10)

    #expect(progress.fraction == 0)
    #expect(progress.remainingSeconds == nil)
}

@Test("Progress can't run past the end of the clip")
func fractionIsClamped() {
    // A reader can hand back a frame a shade past the duration it reported.
    let progress = AnalysisProgress(analysedSeconds: 121, clipSeconds: 120, elapsedSeconds: 40)

    #expect(progress.fraction == 1)
    #expect(progress.isFinished)
}

@Test("Speed is media seconds per second of waiting")
func speedIsRelativeToRealTime() {
    let progress = AnalysisProgress(analysedSeconds: 60, clipSeconds: 120, elapsedSeconds: 20)

    #expect(progress.speed == 3)
}

@Test("No rate is claimed in the first second, while the model is still loading")
func speedIsWithheldEarly() {
    let progress = AnalysisProgress(analysedSeconds: 0.2, clipSeconds: 120, elapsedSeconds: 0.4)

    #expect(progress.speed == nil)
    #expect(progress.remainingSeconds == nil)
}

@Test("Time left comes from the rate so far")
func remainingFromRate() {
    // A third of the way in at 3× real time: 80 seconds of clip left, so 
    // roughly 27 seconds of waiting.
    let progress = AnalysisProgress(analysedSeconds: 40, clipSeconds: 120, elapsedSeconds: 20)

    let remaining = try! #require(progress.remainingSeconds)
    #expect(abs(remaining - 40) < 0.001)
}

@Test("A finished pass has nothing left to wait for")
func finishedHasNoRemaining() {
    let progress = AnalysisProgress(analysedSeconds: 120, clipSeconds: 120, elapsedSeconds: 30)

    #expect(progress.remainingSeconds == nil)
    #expect(progress.remainingDescription == nil)
}

@Test("The countdown is rounded to something worth saying")
func remainingIsRounded() {
    // 4 seconds left reads as a vague "few seconds" rather than ticking down.
    let nearlyDone = AnalysisProgress(analysedSeconds: 116, clipSeconds: 120, elapsedSeconds: 29)
    #expect(nearlyDone.remainingDescription == "a few seconds left")

    // 2 minutes at 1× real time.
    let halfway = AnalysisProgress(analysedSeconds: 120, clipSeconds: 240, elapsedSeconds: 120)
    #expect(halfway.remainingDescription == "about 2 min left")
}

@Test("Negative inputs can't produce nonsense")
func negativesAreRejected() {
    let progress = AnalysisProgress(analysedSeconds: -5, clipSeconds: -120, elapsedSeconds: -1)

    #expect(progress.fraction == 0)
    #expect(progress.speed == nil)
}
