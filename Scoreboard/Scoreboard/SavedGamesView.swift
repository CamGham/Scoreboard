//
//  SavedGamesView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI
import AVFoundation

/// The library of analysed videos.
///
/// Owns the whole `List` — rather than being a section of someone else's — so swipe
/// actions and the delete confirmation hang off one container. Whatever sits above the
/// library goes in `header`.
struct SavedGamesView<Header: View>: View {
    let store: ShotStore
    @ViewBuilder var header: Header

    @State private var summaries: [SavedGameSummary] = []

    var body: some View {
        List {
            header
                .libraryRow()

            if summaries.isEmpty {
                ContentUnavailableView {
                    Label("No saved games", systemImage: "list.clipboard")
                } description: {
                    Text("Analyse a video and it will be kept here, along with any corrections you make.")
                }
                .frame(minHeight: 220)
                .libraryRow()
            } else {
                ForEach(summaries) { summary in
                    SavedGameListRow(summary: summary, store: store) {
                        delete(summary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task { reload() }
        // Re-read when coming back from a detail view, since corrections there change
        // the totals shown here.
        .onAppear { reload() }
    }

    private func reload() {
        summaries = store.summaries()
    }

    /// Removes everything stored for the video — every run, the user's corrections and
    /// marked sections. The video itself stays in Photos.
    private func delete(_ summary: SavedGameSummary) {
        try? store.delete(assetIdentifier: summary.assetIdentifier)

        // Re-read rather than trusting the removal, so a failed delete leaves the row.
        withAnimation { reload() }
    }
}

private extension View {
    /// Lets non-game content (the header, the empty state) sit on the screen's
    /// background rather than as a table cell.
    func libraryRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    /// Asks before deleting a saved game, since its corrections can't be recovered.
    func deleteAnalysisConfirmation(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Delete this analysis?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Analysis", role: .destructive, action: onConfirm)
        } message: {
            Text("Every run and any corrections you've made will be removed. The video stays in your library.")
        }
    }
}

/// One saved game in the library, with its own delete confirmation — so the dialog is
/// anchored to the row being deleted.
private struct SavedGameListRow: View {
    let summary: SavedGameSummary
    let store: ShotStore
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationLink {
            SavedGameDetailView(summary: summary, store: store, onDelete: onDelete)
        } label: {
            SavedGameRow(summary: summary)
        }
        // Standard row, but over the screen's gradient rather than white.
        .listRowBackground(Color.clear)
        // Not `role: .destructive` — that removes the row straight away, before the
        // confirmation has been answered.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .deleteAnalysisConfirmation(isPresented: $isConfirmingDelete, onConfirm: onDelete)
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
        }
        .padding(.vertical, 4)
    }
}

/// A saved run, reopened. Corrections made here are written straight back.
struct SavedGameDetailView: View {
    let summary: SavedGameSummary
    let store: ShotStore

    /// Carries out the deletion once confirmed. The library owns it so its rows stay in
    /// step; this view just leaves afterwards.
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

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

    /// Sections marked for another pass, kept with the video rather than the run.
    @State private var plan: ReanalysisPlan?

    /// The scrubber view over the original clip. Only offered once the video itself has
    /// been resolved — there is nothing to scrub without it.
    @State private var showReview = false

    @State private var isConfirmingDelete = false

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
            if asset != nil, !gameState.reviewableAttempts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showReview = true
                    } label: {
                        Label("Review", systemImage: "film")
                    }
                    .accessibilityHint("Scrub the whole video with every shot marked")
                }
            }

            if runCount > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showComparison = true
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Analysis", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .deleteAnalysisConfirmation(isPresented: $isConfirmingDelete) {
            onDelete()
            dismiss()
        }
        .fullScreenCover(isPresented: $showReview) {
            if let asset {
                AnalysisReviewView(
                    gameState: gameState,
                    asset: asset,
                    orientedVideoSize: orientedVideoSize,
                    onDismiss: { showReview = false },
                    frameProvider: frameProvider,
                    sections: plan?.sections ?? [],
                    onSectionsChanged: { saveSections($0) },
                    exclusions: truth?.exclusions ?? [],
                    onExclusionsChanged: { saveExclusions($0) },
                    rim: truth?.rim,
                    onAttemptsMerged: { saveMergedRun() }
                )
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
        plan = store.loadPlan(for: summary.assetIdentifier)
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
                    orientation: VideoProcessor.orientation(from: transform ?? .identity)
                )
            }
        } catch let failure as VideoLibrary.LookupFailure {
            videoFailure = failure
        } catch {
            videoFailure = .assetMissing
        }
    }

    /// Write a re-analysed timeline back over the run it came from.
    ///
    /// The same run rather than a new one: re-analysing a window is a correction to this
    /// pass, not a separate attempt at the whole video, and a new run per section would
    /// bury the comparison the run list exists for.
    private func saveMergedRun() {
        guard var updated = run else { return }

        updated.attempts = gameState.reviewableAttempts
        run = updated

        try? store.saveRun(updated)
        try? store.refreshSummary(
            for: summary.assetIdentifier,
            attempts: updated.attempts
        )
    }

    private func saveExclusions(_ zones: [ExclusionZone]) {
        var document = truth ?? GroundTruthDocument(assetIdentifier: summary.assetIdentifier)
        document.exclusions = zones

        truth = document
        try? store.saveTruth(document)
    }

    private func saveSections(_ updated: [ReanalysisSection]) {
        var document = plan ?? ReanalysisPlan(assetIdentifier: summary.assetIdentifier)
        document.sections = updated

        plan = document
        try? store.savePlan(document)
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
