//
//  ShotTimelineView.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import SwiftUI

/// Compact heads-up display over the video: running tally plus what the detector is
/// doing right now. Mostly a tuning aid — if a shot isn't being picked up, this shows
/// whether the rim was found and whether an attempt ever opened.
struct LiveShotReadout: View {
    let gameState: GameState

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text("\(gameState.stats.makes)/\(gameState.stats.attempts)")
                    .font(.headline.monospacedDigit())
                Text("FG \(gameState.stats.fieldGoalPercentage, specifier: "%.0f")%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(statusText)
                    .font(.caption.weight(.medium))
                Text(rimText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(statusColour.opacity(0.6), lineWidth: 1.5)
        )
    }

    private var statusText: String {
        guard let attempt = gameState.currentAttempt else {
            return "Watching"
        }
        if attempt.rimContacts > 0 {
            return "Shot · rim contact"
        }
        return attempt.wasDetectedLate ? "Shot (late pickup)" : "Shot in flight"
    }

    private var statusColour: Color {
        gameState.currentAttempt != nil ? .yellow : .secondary
    }

    private var rimText: String {
        gameState.rim == nil ? "No rim yet" : "Rim locked"
    }
}

/// Every resolved attempt, newest first.
struct ShotTimelineView: View {
    let gameState: GameState

    /// Detection tally, so the moving crop can be judged against the full-frame sweep.
    var ballStats: BallDetectionStats?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Attempts", value: "\(gameState.stats.attempts)")
                    LabeledContent("Made", value: "\(gameState.stats.makes)")
                    LabeledContent("Missed", value: "\(gameState.stats.misses)")
                    LabeledContent(
                        "Field goal",
                        value: String(format: "%.0f%%", gameState.stats.fieldGoalPercentage)
                    )
                    LabeledContent("Points", value: "\(gameState.stats.points)")
                } header: {
                    Text("Totals")
                } footer: {
                    Text("Every make counts as two. Separating twos from threes needs court calibration, which isn't wired up yet.")
                }

                if let stats = ballStats {
                    Section {
                        LabeledContent("Frames", value: "\(stats.framesProcessed)")
                        LabeledContent(
                            "Ball found",
                            value: String(format: "%.0f%% of frames", stats.overallHitRate * 100)
                        )
                        LabeledContent(
                            "In crop",
                            value: String(format: "%.0f%% of %d", stats.croppedHitRate * 100, stats.croppedAttempts)
                        )
                        LabeledContent(
                            "Full frame",
                            value: String(format: "%.0f%% of %d", stats.fullFrameHitRate * 100, stats.fullFrameAttempts)
                        )
                        LabeledContent(
                            "Mean confidence",
                            value: String(format: "%.2f", stats.meanConfidence)
                        )
                    } header: {
                        Text("Ball detection")
                    } footer: {
                        Text("Compare the crop's hit rate against the full-frame sweep. A trajectory fit needs consecutive sightings, so the share of frames with a ball matters more than confidence.")
                    }
                }

                Section("Shots") {
                    if gameState.shotTimeline.isEmpty {
                        Text("No shots detected yet")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(gameState.shotTimeline.reversed()) { attempt in
                        ShotRow(attempt: attempt)
                    }
                }

                if !gameState.abandonedAttempts.isEmpty {
                    Section {
                        ForEach(gameState.abandonedAttempts.reversed()) { attempt in
                            ShotRow(attempt: attempt)
                        }
                    } header: {
                        Text("Unresolved")
                    } footer: {
                        Text("Opened as a shot but the ball was lost before an outcome could be read. These are excluded from the totals.")
                    }
                }
            }
            .navigationTitle("Shot timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ShotRow: View {
    let attempt: ShotAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(colour)
                Text(attempt.result.rawValue.capitalized)
                    .font(.headline)

                Spacer()

                Text(frameRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let crossing = decidingCrossing {
                    // 0.0 is dead centre of the ring, 1.0 is the ring itself.
                    Tag(text: String(format: "offset %.2f", abs(crossing.normalisedOffset)))
                }
                if attempt.rimContacts > 0 {
                    Tag(text: "rim ×\(attempt.rimContacts)")
                }
                if attempt.wasDetectedLate {
                    Tag(text: "late pickup")
                }
                if attempt.isCloseCall {
                    Tag(text: "close call", tint: .orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var decidingCrossing: RimCrossing? {
        attempt.crossings.min(by: { abs($0.normalisedOffset) < abs($1.normalisedOffset) })
    }

    private var frameRange: String {
        guard let end = attempt.endFrame else { return "\(attempt.startFrame)–" }
        return "\(attempt.startFrame)–\(end)"
    }

    private var symbol: String {
        switch attempt.result {
        case .made: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .abandoned: return "questionmark.circle.fill"
        case .inProgress: return "circle.dotted"
        }
    }

    private var colour: Color {
        switch attempt.result {
        case .made: return .green
        case .missed: return .red
        case .abandoned: return .secondary
        case .inProgress: return .yellow
        }
    }
}

private struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
