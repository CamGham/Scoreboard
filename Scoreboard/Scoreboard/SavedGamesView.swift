//
//  SavedGamesView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI
import AVFoundation

/// The library of analysed videos.
struct SavedGamesView: View {
    let store: ShotStore

    @State private var summaries: [SavedGameSummary] = []

    var body: some View {
        Group {
            if summaries.isEmpty {
                ContentUnavailableView {
                    Label("No saved games", systemImage: "list.clipboard")
                } description: {
                    Text("Analyse a video and it will be kept here, along with any corrections you make.")
                }
                .frame(minHeight: 220)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            SavedGameDetailView(summary: summary, store: store)
                        } label: {
                            SavedGameRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { reload() }
        // Re-read when coming back from a detail view, since corrections there change
        // the totals shown here.
        .onAppear { reload() }
    }

    private func reload() {
        summaries = store.summaries()
    }
}

private struct SavedGameRow: View {
    let summary: SavedGameSummary

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("\(summary.makes)")
                    .font(.title2.bold().monospacedDigit())
                Text("of \(summary.attempts)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.analysedAt, format: .dateTime.weekday(.wide).day().month())
                    .font(.headline)

                Text(summary.analysedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ShotTag(text: String(format: "FG %.0f%%", summary.fieldGoalPercentage))

                    if summary.runCount > 1 {
                        ShotTag(text: "\(summary.runCount) analyses", tint: .blue)
                    }

                    if summary.reviewed > 0 {
                        ShotTag(
                            text: String(format: "%d reviewed · %.0f%% agreed",
                                         summary.reviewed, summary.agreementRate),
                            tint: .green
                        )
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A saved run, reopened. Corrections made here are written straight back.
struct SavedGameDetailView: View {
    let summary: SavedGameSummary
    let store: ShotStore

    @State private var gameState = GameState()
    @State private var truth: GroundTruthDocument?
    @State private var run: AnalysisRun?

    /// The video behind the run. Needed for shot cards and replay; the numbers work
    /// without it.
    @State private var asset: AVAsset?
    @State private var frameProvider: ShotFrameProvider?
    @State private var orientedVideoSize: CGSize = .zero

    @State private var isLoading = true
    @State private var videoFailure: VideoLibrary.LookupFailure?

    @State private var runCount = 0
    @State private var showComparison = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
            } else if run == nil {
                ContentUnavailableView {
                    Label("Analysis missing", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The saved run for this video couldn't be read.")
                }
            } else {
                ShotTimelineView(
                    gameState: gameState,
                    ballStats: run?.ballStats,
                    frameProvider: frameProvider,
                    asset: asset,
                    orientedVideoSize: orientedVideoSize
                )
                .safeAreaInset(edge: .top) {
                    if let videoFailure {
                        VideoUnavailableBanner(failure: videoFailure)
                    }
                }
            }
        }
        .navigationTitle(summary.analysedAt.formatted(.dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if runCount > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showComparison = true
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
        }
        .sheet(isPresented: $showComparison) {
            RunComparisonView(
                assetIdentifier: summary.assetIdentifier,
                store: store,
                onDismiss: { showComparison = false }
            )
        }
        .task { await load() }
    }

    private func load() async {
        guard isLoading else { return }

        let loaded = store.load(for: summary.assetIdentifier)
        run = loaded.run
        truth = loaded.truth
        runCount = store.runs(for: summary.assetIdentifier).count

        if let run = loaded.run {
            gameState.load(run: run, truth: loaded.truth)
            gameState.onVerdictChanged = { attempt in
                recordVerdict(attempt)
            }
        }

        isLoading = false

        // The video is a bonus, not a requirement — stats and the timeline stand on
        // their own if it's been deleted or access is refused.
        do {
            let resolved = try await VideoLibrary.asset(for: summary.assetIdentifier)
            asset = resolved
            frameProvider = ShotFrameProvider(asset: resolved)

            if let track = try? await resolved.loadTracks(withMediaType: .video).first {
                let natural = try? await track.load(.naturalSize)
                let transform = try? await track.load(.preferredTransform)
                orientedVideoSize = VideoLayout.orientedSize(
                    natural ?? .zero,
                    orientation: orientation(from: transform ?? .identity)
                )
            }
        } catch let failure as VideoLibrary.LookupFailure {
            videoFailure = failure
        } catch {
            videoFailure = .assetMissing
        }
    }

    private func orientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    private func recordVerdict(_ attempt: ShotAttempt) {
        guard let time = attempt.keyTime else { return }

        var document = truth ?? GroundTruthDocument(assetIdentifier: summary.assetIdentifier)
        document.shots = GroundTruthMatcher.record(
            verdict: attempt.userVerdict,
            atTime: time,
            into: document.shots
        )

        truth = document
        try? store.saveTruth(document)

        // Keep the library row in step with the corrected totals, preserving the run
        // count rather than flattening it back to one.
        try? store.refreshSummary(
            for: summary.assetIdentifier,
            attempts: gameState.reviewableAttempts
        )
    }
}

private struct VideoUnavailableBanner: View {
    let failure: VideoLibrary.LookupFailure

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.slash")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var title: String {
        switch failure {
        case .notAuthorized: return "Photo access needed"
        case .assetMissing: return "Video unavailable"
        }
    }

    private var detail: String {
        switch failure {
        case .notAuthorized:
            return "Allow photo access to see frames and replays. Stats still work."
        case .assetMissing:
            return "The original video has been deleted or is on another device."
        }
    }
}
