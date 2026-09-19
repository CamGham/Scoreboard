//
//  GameState.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/01/2026.
//

import Foundation
import SwiftUI

struct ShotStats: Equatable {
    var attempts: Int = 0
    var makes: Int = 0

    var misses: Int { attempts - makes }

    /// Field-goal percentage, 0–100. Zero attempts reads as 0.
    var fieldGoalPercentage: Double {
        attempts > 0 ? (Double(makes) / Double(attempts)) * 100 : 0
    }

    /// Points, counting every make as two. Distinguishing twos from threes needs court
    /// calibration the pipeline doesn't have yet.
    var points: Int { makes * 2 }
}

/// Main-actor view of the game, fed by `ShotTracker` from the frame-processing thread.
@MainActor
@Observable
final class GameState {

    /// Latest frame's worth of overlay data.
    private(set) var snapshot = GameSnapshot()

    /// Every attempt the detector has resolved, newest last.
    private(set) var shotTimeline: [ShotAttempt] = []

    /// Attempts that never resolved. Kept apart from the stats but surfaced for tuning.
    private(set) var abandonedAttempts: [ShotAttempt] = []

    private(set) var stats = ShotStats()

    /// Frame of the most recent made basket, for a score flash in the UI.
    private(set) var lastMadeFrame: Int?

    /// Constructible off the main actor — `VisionTracker` owns one and is created on the
    /// frame-processing thread. Every stored property starts from a plain value, so
    /// there is nothing isolated to touch here; all *mutation* stays main-actor bound.
    nonisolated init() {}

    // Convenience accessors so views don't have to reach through `snapshot`.
    var ballHistory: [BallObservation] { snapshot.ballHistory }
    var rim: HoopGeometry? { snapshot.rim }
    var ballState: BallState { snapshot.ballState }
    var arcPoints: [CGPoint] { snapshot.arcPoints }
    var currentAttempt: ShotAttempt? { snapshot.currentAttempt }
    var predictedCrossingFrame: Double? { snapshot.predictedCrossingFrame }

    func apply(_ incoming: GameSnapshot) {
        // Snapshots are delivered by hopping onto the main actor, which does not
        // guarantee arrival order. Dropping stale ones keeps the overlay monotonic.
        guard incoming.sequence > snapshot.sequence else { return }
        snapshot = incoming
    }

    func handle(_ event: ShotEvent) {
        switch event {
        case .attemptStarted:
            break

        case .rimContact:
            break

        case .attemptResolved(let attempt):
            switch attempt.result {
            case .made:
                shotTimeline.append(attempt)
                stats.attempts += 1
                stats.makes += 1
                lastMadeFrame = attempt.endFrame

            case .missed:
                shotTimeline.append(attempt)
                stats.attempts += 1

            case .abandoned:
                abandonedAttempts.append(attempt)

            case .inProgress:
                break
            }
        }
    }

    func reset() {
        snapshot = GameSnapshot()
        shotTimeline.removeAll()
        abandonedAttempts.removeAll()
        stats = ShotStats()
        lastMadeFrame = nil
    }
}
