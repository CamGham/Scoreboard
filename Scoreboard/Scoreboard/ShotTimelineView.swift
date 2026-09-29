//
//  ShotTimelineView.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import SwiftUI
import AVFoundation

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

    /// Supplies the still frame each card is drawn on. Nil for the live camera path,
    /// where there is no file to seek back into.
    var frameProvider: ShotFrameProvider?

    /// Backing asset and its oriented size, for replaying a shot. Nil on the camera path.
    var asset: AVAsset?
    var orientedVideoSize: CGSize = .zero

    @State private var replaying: ShotAttempt?

    var body: some View {
        NavigationStack {
            List {
                totalsSection
                
                if gameState.accuracy.reviewed > 0 {
                    detectorAccuracySection
                }
                
                if ballStats != nil {
                    ballDetectionSection
                }
                
                shotsSection
                
                if !gameState.abandonedAttempts.isEmpty {
                    unresolvedSection
                }
            }
            .navigationTitle("Shot timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(item: $replaying) { attempt in
            if let asset {
                // Re-read from game state rather than using the captured copy, so a
                // ruling made in the sheet is reflected in the sheet.
                let live = gameState.attempt(withID: attempt.id) ?? attempt

                ShotReplayView(
                    attempt: live,
                    asset: asset,
                    orientedVideoSize: orientedVideoSize,
                    onDismiss: { replaying = nil },
                    onVerdict: { gameState.setVerdict($0, for: attempt.id) }
                )
            }
        }
        .onChange(of: replaying) { old, new in
            print("\(new?.id.uuidString ?? "UNknown")")
        }
    }
    
    // MARK: - Section Views
    
    private var totalsSection: some View {
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
    }
    
    private var detectorAccuracySection: some View {
        Section {
            let accuracy = gameState.accuracy
            LabeledContent("Shots reviewed", value: "\(accuracy.reviewed)")
            LabeledContent(
                "Detector agreed",
                value: String(format: "%d (%.0f%%)", accuracy.agreed, accuracy.agreementRate)
            )
            LabeledContent("Wrong call", value: "\(accuracy.wrongCalls)")
            LabeledContent("Not a shot", value: "\(accuracy.falsePositives)")
        } header: {
            Text("Detector accuracy")
        } footer: {
            Text("Measured against your corrections. Every shot you rule on is a labelled example, so this becomes more meaningful the more you review.")
        }
    }
    
    private var ballDetectionSection: some View {
        Section {
            if let stats = ballStats {
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
            }
        } header: {
            Text("Ball detection")
        } footer: {
            Text("Compare the crop's hit rate against the full-frame sweep. A trajectory fit needs consecutive sightings, so the share of frames with a ball matters more than confidence.")
        }
    }
    
    private var shotsSection: some View {
        Section("Shots") {
            if gameState.shotTimeline.isEmpty {
                Text("No shots detected yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(gameState.shotTimeline.reversed()) { attempt in
                ShotCardView(attempt: attempt, provider: frameProvider)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Only seekable shots can be replayed.
                        if asset != nil, attempt.keyTime != nil {
                            replaying = attempt
                        }
                    }
            }
        }
    }
    
    private var unresolvedSection: some View {
        Section {
            ForEach(gameState.abandonedAttempts.reversed()) { attempt in
                ShotCardView(attempt: attempt, provider: frameProvider)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if asset != nil, attempt.keyTime != nil {
                            replaying = attempt
                        }
                    }
            }
        } header: {
            Text("Unresolved")
        } footer: {
            Text("Opened as a shot but the ball was lost before an outcome could be read. These are excluded from the totals.")
        }
    }
}
