//
//  VideoView.swift
//  Scoreboard
//
//  Created by Cam Graham on 09/11/2025.
//

import SwiftUI
import AVKit

enum AssetState {
    case unSelected
    case loading
    case processing
    case failed
    case ready
}
struct VideoView: View {
    @Environment(\.dismiss) var dismiss
    
    @State var asset: AVURLAsset?
    @State var assetIdentifier: String?
    @State var videoProcessor: VideoProcessor?
    
    @State var showLibrary = false
    @State var assetState = AssetState.unSelected
    
    @State var showHistory = false

    /// Rim resolution happens before playback: the detector opens no attempts without a
    /// scoring plane, so anything that happened before the rim was known would be lost.
    @State var showRimPlacement = false
    @State var rimPreflight: RimPreflight.Result?

    /// Decodes the one frame each shot card is drawn on. Built once per asset, since it
    /// caches decoded frames across the whole timeline.
    @State var frameProvider: ShotFrameProvider?

    /// Saved analysis and corrections for this video.
    @State var store = ShotStore()
    @State var truth: GroundTruthDocument?

    /// Identity of the analysis pass in progress, so repeated saves update one run.
    @State var currentRunID: UUID?

    /// Runs already stored for this video, checked before analysing again.
    @State var existingRuns: [RunMetadata] = []
    @State var showExistingAnalysisAlert = false

    /// Stretches of this video the user has flagged for another pass.
    @State var plan: ReanalysisPlan?

    /// Shown the moment the last frame has been analysed. The processing view is a tuning
    /// instrument; this is what the result is actually for.
    @State var showAnalysisReview = false

    /// Whether the frames are being drawn as they are analysed.
    ///
    /// Watching is how a rim in the wrong place or a ball going undetected gets spotted,
    /// so it stays the offered default — but it costs a decoded image and a full redraw
    /// per frame, and once a clip's setup is known to be right that is pure waiting.
    @State var showsPreview = true

    /// False until the user has picked how to run this pass.
    @State var hasStartedAnalysis = false

    /// When the pass started, for the rate the progress view reports.
    @State var analysisStartedAt: Date?

    /// Length of the clip, for progress. Zero until it loads.
    @State var clipDuration: Double = 0

    /// Whether the blocked-area editor is up, drawn on the frame on screen.
    @State var showZoneEditor = false
    var body: some View {
        VStack {
            switch assetState {
            case .unSelected:
                ContentUnavailableView {
                    Label("No video selected", systemImage: "video.fill")
                } description: {
                    Text("Tap the button below to get started")
                } actions: {
                    Button("Open Library", systemImage: "photo.badge.plus.fill") {
                        showLibrary.toggle()
                    }
                }
            case .failed:
                ContentUnavailableView {
                    Label("Could not load video", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text("Something went wrong when loading the video. Please try again.")
                } actions: {
                    Button("Open Library", systemImage: "photo.badge.plus.fill") {
                        showLibrary.toggle()
                    }
                }
            case .loading, .processing:
                ProgressView("Loading...")
            case .ready:
                if let videoProcessor, let currentFrame = videoProcessor.currentFrame {
                    Group {
                        if showsPreview {
                            currentFrame
                                .resizable()
                                .scaledToFit()
                                .overlay { DetectionOverlayView(processor: videoProcessor) }
                        } else {
                            // Nothing is drawn onto the frames any more, so the numbers
                            // stand in for them.
                            AnalysisProgressStage(
                                poster: currentFrame,
                                progress: progress(for: videoProcessor),
                                stats: videoProcessor.tracker.gameState.stats,
                                shotsFound: videoProcessor.tracker.gameState.reviewableAttempts.count,
                                isRunning: videoProcessor.playback == .resume,
                                onShowPreview: { setPreview(true) }
                            )
                        }
                    }
                    // Rim work needs the picture: both of these place a box on the frame,
                    // and the banner reads state that only moves while frames are drawn.
                    .overlay(alignment: .top) {
                        if showsPreview, videoProcessor.tracker.gameState.rim == nil {
                            RimMissingBanner {
                                showRimPlacement = true
                            }
                            .padding(.top, 60)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if showsPreview {
                            HStack(spacing: 8) {
                                Button {
                                    showRimPlacement = true
                                } label: {
                                    Label("Rim", systemImage: "scope")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)

                                // Watching is when a bin or a sign being read as the ball
                                // is actually noticed, so the fix is offered right here.
                                Button {
                                    withAnimation { videoProcessor.playback = .pause }
                                    showZoneEditor = true
                                } label: {
                                    Label("Block area", systemImage: "nosign")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)
                                .tint(truth?.exclusions.isEmpty == false ? .red : nil)
                            }
                            .padding()
                        }
                    }
                    .overlay(alignment: .bottom) {
                        HStack {
                            Spacer()
                            chromeButton {
                                showHistory.toggle()
                            } label: {
                                Image(systemName: "list.clipboard")
                            }
                            .padding()
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if hasStartedAnalysis {
                            HStack {
                                chromeButton(circular: true) {
                                    togglePlayback(videoProcessor)
                                } label: {
                                    Image(systemName: videoProcessor.playback == .pause ? "play.fill" : "pause.fill")
                                }
                                .contentTransition(.symbolEffect(.replace))

                                // Switchable mid-pass: watching costs a redraw a frame,
                                // and the moment you stop needing to see it, you stop
                                // paying for it.
                                chromeButton(circular: true) {
                                    setPreview(!showsPreview)
                                } label: {
                                    Image(systemName: showsPreview ? "eye.slash" : "eye")
                                }
                                .contentTransition(.symbolEffect(.replace))

                                chromeButton {
                                    Task { await videoProcessor.next() }
                                } label: {
                                    Text("next")
                                }
                            }
                            .padding(.bottom)
                        }
                    }
                    .overlay {
                        if !hasStartedAnalysis {
                            AnalysisStartCard(
                                clipDuration: clipDuration,
                                hasRim: videoProcessor.tracker.gameState.rim != nil,
                                onWatch: { startAnalysis(watching: true) },
                                onRunWithoutWatching: { startAnalysis(watching: false) }
                            )
                        }
                    }
                }
            }
            
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading, content: {
            Group {
                if #available(iOS 26.0, *) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .padding(4)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                }
            }
            .padding(4)
        })
        .sheet(isPresented: $showLibrary) {
            VideoPicker(
                isPresented: $showLibrary,
                selectedAsset: $asset,
                assetIdentifier: $assetIdentifier,
                assetState: $assetState
            )
        }
        .onAppear(perform: {
            showLibrary = true
        })
        .task(id: asset) {
            guard let asset else { return }
            assetState = .processing
            do {
                let processor = try await VideoProcessor.create(videoAsset: asset)
                videoProcessor = processor
                frameProvider = ShotFrameProvider(asset: asset)

                // Progress is measured against this; without it the panel can only count
                // upwards with no idea of how far there is to go.
                clipDuration = ((try? await asset.load(.duration))?.seconds).flatMap {
                    $0.isFinite ? $0 : nil
                } ?? 0

                // Load anything the user has already told us about this video. A saved
                // rim means they never have to place it twice, and saved rulings are
                // reapplied to attempts as they are detected.
                if let assetIdentifier {
                    // Analysing again adds a run rather than replacing the last one, so
                    // say so before it happens.
                    existingRuns = store.runs(for: assetIdentifier)
                    if !existingRuns.isEmpty {
                        showExistingAnalysisAlert = true
                    }

                    let stored = store.loadTruth(for: assetIdentifier)
                    truth = stored
                    plan = store.loadPlan(for: assetIdentifier)

                    // Applied before a single frame is read: a zone the user drew on an
                    // earlier pass is knowledge about this video, not about that run.
                    processor.tracker.setExclusionZones(stored.exclusions)
                    processor.tracker.gameState.applyStoredTruth(stored.shots)

                    if let savedRim = stored.rim {
                        processor.tracker.setUserRim(savedRim)
                    }

                    processor.tracker.gameState.onVerdictChanged = { [assetIdentifier] attempt in
                        recordVerdict(for: attempt, assetIdentifier: assetIdentifier)
                    }
                }

                // Resolve the rim across the whole clip before a single frame is
                // processed. Sampling spread-out frames beats the opening seconds: a rim
                // screened by players at the start usually isn't later on, and the rim
                // doesn't move, so every sample is equally valid.
                if let model = await processor.tracker.awaitVisionModel() {
                    let result = await RimPreflight.scan(asset: asset, model: model)
                    rimPreflight = result

                    if truth?.rim != nil {
                        // A hand-placed rim outranks anything the pre-flight found.
                    } else if let geometry = result.geometry {
                        processor.tracker.seedRim(geometry)
                    } else {
                        // Nothing found anywhere in the clip — ask rather than let the
                        // user watch a whole video that could never score.
                        showRimPlacement = true
                    }
                }

                assetState = .ready
            } catch {
                assetState = .failed
                print("error \(error.localizedDescription)")
            }
        }
        .alert("Already analysed", isPresented: $showExistingAnalysisAlert) {
            Button("Analyse again") { }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text(existingAnalysisMessage)
        }
        .fullScreenCover(isPresented: $showZoneEditor) {
            if let frame = videoProcessor?.currentFrame {
                ExclusionZoneEditorView(
                    backdrop: frame,
                    initialZones: truth?.exclusions ?? [],
                    onCancel: { showZoneEditor = false },
                    onConfirm: { zones in
                        saveExclusions(zones)
                        showZoneEditor = false
                    }
                )
            }
        }
        .sheet(isPresented: $showRimPlacement) {
            if let videoProcessor, let frame = videoProcessor.currentFrame {
                RimPlacementView(
                    backdrop: frame,
                    initialGeometry: videoProcessor.tracker.gameState.rim,
                    onCancel: { showRimPlacement = false },
                    onConfirm: { geometry in
                        videoProcessor.tracker.setUserRim(geometry)
                        saveRim(geometry)
                        showRimPlacement = false
                    }
                )
            }
        }
        .onChange(of: showHistory) { _, isShowing in
            if isShowing { saveRun() }
        }
        // The reader has run out of frames: the numbers are final, so save them and hand
        // the user the reviewable version of the clip.
        .onChange(of: videoProcessor?.isComplete ?? false) { _, finished in
            guard finished else { return }
            saveRun()
            showAnalysisReview = true
        }
        .fullScreenCover(isPresented: $showAnalysisReview) {
            if let videoProcessor, let asset {
                AnalysisReviewView(
                    gameState: videoProcessor.tracker.gameState,
                    asset: asset,
                    orientedVideoSize: videoProcessor.orientedVideoSize,
                    onDismiss: { showAnalysisReview = false },
                    frameProvider: frameProvider,
                    ballStats: videoProcessor.tracker.ballDetector?.stats,
                    sections: plan?.sections ?? [],
                    // No identifier means nowhere to write marks, so don't offer to take
                    // them — a mark that silently evaporates is worse than none.
                    onSectionsChanged: assetIdentifier == nil ? nil : { saveSections($0) },
                    exclusions: truth?.exclusions ?? [],
                    onExclusionsChanged: assetIdentifier == nil ? nil : { saveExclusions($0) },
                    rim: videoProcessor.tracker.gameState.rim ?? truth?.rim,
                    onAttemptsMerged: { saveRun() }
                )
            }
        }
        .onDisappear { saveRun() }
        .sheet(isPresented: $showHistory) {
            if let videoProcessor {
                ShotTimelineView(
                    gameState: videoProcessor.tracker.gameState,
                    ballStats: videoProcessor.tracker.ballDetector?.stats,
                    frameProvider: frameProvider,
                    asset: asset,
                    orientedVideoSize: videoProcessor.orientedVideoSize
                )
            }
        }
    }

    /// How the pass is going, in media time against wall-clock time.
    func progress(for videoProcessor: VideoProcessor) -> AnalysisProgress {
        AnalysisProgress(
            analysedSeconds: videoProcessor.analysedTime,
            clipSeconds: clipDuration,
            elapsedSeconds: analysisStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
    }

    /// Start the pass the way the user asked for it.
    func startAnalysis(watching: Bool) {
        guard let videoProcessor else { return }

        hasStartedAnalysis = true
        setPreview(watching)
        resume(videoProcessor)
    }

    func togglePlayback(_ videoProcessor: VideoProcessor) {
        if videoProcessor.playback == .pause {
            resume(videoProcessor)
        } else {
            withAnimation { videoProcessor.playback = .pause }
        }
    }

    /// The bottom-bar buttons, in whichever material this OS has.
    ///
    /// One place for the availability split: it was previously written out per button,
    /// which meant every new control arrived as two near-identical copies.
    @ViewBuilder
    func chromeButton<Label: View>(
        circular: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(circular ? .circle : .roundedRectangle)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
                .buttonBorderShape(circular ? .circle : .roundedRectangle)
        }
    }

    func setPreview(_ isOn: Bool) {
        showsPreview = isOn
        videoProcessor?.producesPreviewFrames = isOn
    }

    func resume(_ videoProcessor: VideoProcessor) {
        // The clock starts at the first resume and keeps running across pauses, so the
        // rate shown is the rate of the whole pass rather than of the last burst.
        if analysisStartedAt == nil { analysisStartedAt = Date() }

        withAnimation { videoProcessor.playback = .resume }

        Task.detached(priority: .userInitiated) {
            await videoProcessor.play()
        }
    }


    var existingAnalysisMessage: String {
        let count = existingRuns.count
        let passes = count == 1 ? "once" : "\(count) times"

        guard let latest = existingRuns.first else {
            return "This video has been analysed before."
        }

        let when = latest.analysedAt.formatted(.dateTime.day().month().hour().minute())
        return "This video has been analysed \(passes), most recently on \(when) "
            + "(\(latest.makes)/\(latest.attempts)). Analysing again keeps the earlier "
            + "results and your corrections."
    }

    /// Persist this pass of the detector, with the settings that produced it — accuracy
    /// numbers are meaningless without knowing which configuration they came from.
    func saveRun() {
        guard let assetIdentifier, let videoProcessor else { return }

        let gameState = videoProcessor.tracker.gameState
        let attempts = gameState.reviewableAttempts
        guard !attempts.isEmpty else { return }

        // One run id per analysis pass, so repeated saves during a session update the
        // same run rather than piling up near-identical copies.
        let id = currentRunID ?? UUID()
        currentRunID = id

        let run = AnalysisRun(
            id: id,
            assetIdentifier: assetIdentifier,
            configuration: videoProcessor.tracker.currentConfiguration(),
            attempts: attempts,
            ballStats: videoProcessor.tracker.ballDetector?.stats
        )

        try? store.saveRun(run)

        // The library list reads summaries rather than parsing every run.
        try? store.refreshSummary(for: assetIdentifier, attempts: attempts)
    }

    /// Persist a ruling as time-keyed ground truth, so it survives re-analysis.
    func recordVerdict(for attempt: ShotAttempt, assetIdentifier: String) {
        guard let time = attempt.keyTime else { return }

        var document = truth ?? GroundTruthDocument(assetIdentifier: assetIdentifier)
        document.shots = GroundTruthMatcher.record(
            verdict: attempt.userVerdict,
            atTime: time,
            into: document.shots
        )

        truth = document
        try? store.saveTruth(document)
        saveRun()
    }

    /// Persist the marked sections. Their own file, like the corrections: a request for
    /// work still to do outlives any single analysis pass.
    func saveSections(_ updated: [ReanalysisSection]) {
        guard let assetIdentifier else { return }

        var document = plan ?? ReanalysisPlan(assetIdentifier: assetIdentifier)
        document.sections = updated

        plan = document
        try? store.savePlan(document)
    }

    /// Persist blocked-out areas, and apply them to the pass in progress.
    ///
    /// Live rather than only on the next run: the frames already analysed keep whatever
    /// they found, but from here on the decoy is ignored.
    func saveExclusions(_ zones: [ExclusionZone]) {
        guard let assetIdentifier else { return }

        var document = truth ?? GroundTruthDocument(assetIdentifier: assetIdentifier)
        document.exclusions = zones

        truth = document
        try? store.saveTruth(document)

        videoProcessor?.tracker.setExclusionZones(zones)
    }

    func saveRim(_ geometry: HoopGeometry) {
        guard let assetIdentifier else { return }

        var document = truth ?? GroundTruthDocument(assetIdentifier: assetIdentifier)
        document.rim = geometry

        truth = document
        try? store.saveTruth(document)
    }

    
}

//#Preview {
//    VideoView(video: )
//}

