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

    /// How well per-frame detection found players, to judge it against the tracker.
    var playerStats: PlayerDetectionStats?

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

                if let playerStats, playerStats.sampledFrames > 0 {
                    playerDetectionSection(playerStats)
                }

                if let appearance = playerStats?.tracking?.appearance, appearance.comparisons > 0 {
                    appearanceSection(appearance)
                }

                if let identities = gameState.identities, let revisions = identities.revisions {
                    revisionsSection(revisions, record: identities)
                }

                if let identities = gameState.identities, !identities.checks.isEmpty {
                    identityChecksSection(identities)
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
                    onVerdict: { gameState.setVerdict($0, for: attempt.id) },
                    possession: gameState.possession,
                    identities: gameState.identities
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
            LabeledContent(
                "Shooter found",
                value: "\(gameState.shotTimeline.filter { $0.shooter != nil }.count) of \(gameState.shotTimeline.count)"
            )
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
    
    private func appearanceSection(_ summary: AppearanceSeparation.Summary) -> some View {
        Section {
            LabeledContent("Comparisons", value: "\(summary.comparisons)")
            ForEach(AppearanceSeparation.Cue.allCases, id: \.self) { cue in
                let score = summary.score(for: cue)
                LabeledContent(
                    Self.title(for: cue),
                    value: score.compared > 0
                        ? String(
                            format: "%.0f%% of %d · weight %.1f",
                            score.accuracy * 100,
                            score.compared,
                            AppearanceSeparation.weight(for: score)
                        )
                        : "Not measured"
                )
            }
            LabeledContent(
                "All together",
                value: String(format: "%.0f%%", summary.combined.accuracy * 100)
            )
            if let samples = summary.heightSamples, let spread = summary.footSpread {
                LabeledContent(
                    "Height model",
                    value: String(format: "%d samples, feet over %.0f%% of frame", samples, spread * 100)
                )
            }
        } header: {
            Text("Telling players apart")
        } footer: {
            Text("Each clear sample of a player is checked against that player's recent look and the other players' seen on the same frame. 50% is a coin flip; near 100% means the cue tells them apart. The weight is how much the cue counts when identities are checked after players touch. Height is judged against what's typical for that spot on court, once feet have been seen over at least 10% of the frame's height.")
        }
    }

    private func revisionsSection(_ revisions: [IdentityRevision], record: IdentityRecord) -> some View {
        Section {
            if revisions.isEmpty {
                Text("Nothing moved")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(revisions.enumerated()), id: \.offset) { _, revision in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(revision) + " · " + record.players.map(\.label).joined(separator: " ↔ "))
                        .font(.subheadline.monospacedDigit())
                    Text(String(
                        format: "%.1f× better · %d %@",
                        1 / max(revision.ratio, 0.001),
                        revision.tracklets,
                        revision.tracklets == 1 ? "stretch" : "stretches"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Re-solved after the run · \(revisions.count) moved")
        } footer: {
            Text("Once the clip ended, every clear stretch of each player was compared with how they looked elsewhere in the clip, at the same spot across the court. These stretches fitted the other player clearly better, so their labels were swapped.")
        }
    }

    private static func when(_ revision: IdentityRevision) -> String {
        guard let start = revision.startTime else { return "Frame \(revision.startFrame)" }
        let end = revision.endTime.map { " → " + ShotScrubber.timecode($0) } ?? ""
        return ShotScrubber.timecode(start) + end
    }

    private func identityChecksSection(_ record: IdentityRecord) -> some View {
        Section {
            ForEach(Array(record.checks.enumerated()), id: \.offset) { _, check in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(check) + " · " + Self.players(in: check, record: record))
                        .font(.subheadline.monospacedDigit())
                    Text(Self.verdict(check))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if check.outcome == .neverClear, let why = Self.blockedSummary(check, record: record) {
                        Text(why)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Identity checks · " + Self.tally(record.checks))
        } footer: {
            Text("Each time players touched. Scrub the review to the time shown and see whether they really came out swapped. Swap ÷ keep compares how far apart the looks were each way round: above 1 favours the labels as they were, below 1 favours swapping. It takes 25% either way to act. \"One side\" means only one player got clear in time, so their look alone decided it.")
        }
    }

    private static func when(_ check: IdentityCheck) -> String {
        guard let start = check.startTime else { return "Frame \(check.startFrame)" }
        let settled = check.time.map { " → " + ShotScrubber.timecode($0) } ?? ""
        return ShotScrubber.timecode(start) + settled
    }

    private static func players(in check: IdentityCheck, record: IdentityRecord) -> String {
        check.playerIDs
            .map { id in record.players.first { $0.id == id }?.label ?? "?" }
            .joined(separator: " & ")
    }

    private static func verdict(_ check: IdentityCheck) -> String {
        let ratio = check.keepCost.flatMap { keep in
            check.otherCost.map { other in
                keep > 0 ? String(format: " · swap ÷ keep %.2f", other / keep) : ""
            }
        } ?? ""

        let side = check.oneSided == true ? " · one side" : ""

        switch check.outcome {
        case .kept: return "Kept" + side + ratio
        case .swapped: return "Swapped" + side + ratio
        case .tooClose: return "Too close to call" + side + ratio
        case .neverClear:
            return "Never clear · samples " + check.samples.map(String.init).joined(separator: " / ")
        case .noEarlierLook: return "No earlier look to compare with"
        }
    }

    /// Each player's frames since the last touch, by what kept them from being sampled:
    /// "P1 clean 30 · P2 low confidence 41, not matched 9".
    private static func blockedSummary(_ check: IdentityCheck, record: IdentityRecord) -> String? {
        guard let blocked = check.blocked else { return nil }

        return zip(check.playerIDs, blocked).map { id, counts in
            let name = record.players.first { $0.id == id }?.label ?? "?"
            let reasons = [
                ("clean", counts.clean),
                ("no track", counts.noTrack),
                ("not matched", counts.notMatched),
                ("low confidence", counts.lowConfidence),
                ("touching a box with no player", counts.touchingNobody),
            ]
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { "\($0.0) \($0.1)" }

            return name + " " + (reasons.isEmpty ? "no frames" : reasons.joined(separator: ", "))
        }
        .joined(separator: " · ")
    }

    private static func tally(_ checks: [IdentityCheck]) -> String {
        let order: [(IdentityCheck.Outcome, String)] = [
            (.kept, "kept"), (.swapped, "swapped"), (.tooClose, "too close"),
            (.neverClear, "never clear"), (.noEarlierLook, "no look"),
        ]
        return order.compactMap { outcome, name in
            let count = checks.filter { $0.outcome == outcome }.count
            return count > 0 ? "\(count) \(name)" : nil
        }
        .joined(separator: ", ")
    }

    private static func title(for cue: AppearanceSeparation.Cue) -> String {
        switch cue {
        case .head: "Head (hair)"
        case .torso: "Torso"
        case .shorts: "Shorts"
        case .legs: "Legs"
        case .feet: "Feet (shoes)"
        case .height: "Height"
        case .build: "Build"
        }
    }

    private func playerDetectionSection(_ stats: PlayerDetectionStats) -> some View {
        Section {
            LabeledContent(
                "Frames sampled",
                value: "\(stats.sampledFrames) (\(stats.sweepSamples) sweep, \(stats.passSamples) pass)"
            )
            LabeledContent(
                "Players per frame",
                value: String(format: "%.1f detected · %.1f tracked", stats.meanPlayersDetected, stats.meanPlayersTracked)
            )
            if let tracking = stats.tracking {
                LabeledContent("Players followed", value: "\(tracking.tracksConfirmed)")
                LabeledContent(
                    "Mean time followed",
                    value: String(format: "%.0f frames", tracking.meanTrackLifetimeFrames)
                )
                if let identity = tracking.identity {
                    LabeledContent("Players identified", value: "\(identity.playersSeen) of \(identity.playerCount)")
                    LabeledContent("Relinked", value: "\(identity.relinks)")
                    LabeledContent("Tracks with nobody", value: "\(identity.unassignedTracks)")
                    LabeledContent("Checked after overlaps", value: "\(identity.checks)")
                    LabeledContent("Swapped", value: "\(identity.swaps)")
                    LabeledContent("Left uncertain", value: "\(identity.uncertain)")
                }
            }
            LabeledContent(
                "Frames with none",
                value: String(format: "%.0f%%", stats.emptyFrameRate * 100)
            )
            LabeledContent(
                "Persisted",
                value: String(format: "%.0f%% of %d", stats.persistenceRate * 100, stats.pairedDetections)
            )
            LabeledContent(
                "Count change",
                value: String(format: "%.2f per sample", stats.meanCountChange)
            )
            LabeledContent(
                "Below 0.6 floor",
                value: String(format: "%.0f%% of boxes", stats.belowAcceptedShare * 100)
            )
        } header: {
            Text("Player tracking")
        } footer: {
            if stats.tracking?.identity != nil {
                Text("Players followed counts tracks, which break and restart. Relinked is how many of those breaks were joined back up to a player; tracks with nobody were left over once every player was taken. After players touch, their looks are compared with how they looked before: swapped means they came out the other way round, uncertain means it was too close to call or they never got clear. Persisted is the share of players also found in the previous sample; low means boxes flicker.")
            } else if stats.tracking != nil {
                Text("Players followed should match the number of people in shot — more means identities broke and restarted. Persisted is the share of players also found in the previous sample; low means boxes flicker.")
            } else {
                Text("From before the player tracker: \"tracked\" is Apple's object tracker. Persisted is the share of players also found in the previous sample; low means boxes flicker.")
            }
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
