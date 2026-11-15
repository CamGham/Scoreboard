//
//  ScreenAwakeTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 04/11/2026.
//

import Testing
import Foundation
@testable import Scoreboard

@MainActor
@Test("Auto-lock goes off with the first holder and returns with the last")
func screenAwakeFirstAndLastHolder() {
    var applied: [Bool] = []
    let awake = ScreenAwake { applied.append($0) }
    let pass = UUID(), review = UUID()

    awake.hold(pass)
    awake.hold(review)
    awake.release(pass)

    // The review still holds, so the first pass letting go mustn't bring auto-lock back.
    #expect(applied == [true])
    #expect(awake.isHeld)

    awake.release(review)

    #expect(applied == [true, false])
    #expect(!awake.isHeld)
}

@MainActor
@Test("Holding twice counts once, and releasing a non-holder does nothing")
func screenAwakeRepeatedCalls() {
    var applied: [Bool] = []
    let awake = ScreenAwake { applied.append($0) }
    let pass = UUID()

    awake.release(pass)
    awake.hold(pass)
    awake.hold(pass)
    awake.release(pass)
    awake.release(pass)

    #expect(applied == [true, false])
}
