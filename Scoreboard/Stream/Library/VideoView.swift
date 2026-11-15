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

    /// Whether the app is on screen. A pass can't run in the background, so it is held
    /// while the app is away and picked up again on return.
    @Environment(\.scenePhase) private var scenePhase

    /// For handing over to the dashboard once a run is saved. Absent in previews.
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    
    /// A pass saved to finish later, to carry on instead of picking a video. Nil for a
    /// new analysis.
    var continuing: AnalysisSnapshot? = nil

    @State var asset: AVAsset?
    @State var assetIdentifier: String?
    @State var videoProcessor: VideoProcessor?

    /// When the picked video was recorded, for ordering the library by game day.
    @State var capturedAt: Date?
    
    @State var showLibrary = false
    @State var assetState = AssetState.unSelected
    

    /// Rim resolution happens before playback: the detector opens no attempts without a
    /// scoring plane, so anything that happened before the rim was known would be lost.
    @State var showRimPlacement = false
    @State var rimPreflight: RimPreflight.Result?

    /// Decodes the one frame each shot card is drawn on. Built once per asset, since it
    /// caches decoded frames across the whole timeline.
    @State var frameProvider: ShotFrameProvider?

    /// Saved analysis and corrections for this video.
    @State var store = ShotStore()

    /// Where this pass is saved part-way, if iOS ends the app while it's away — see
    /// `AnalysisSnapshot`.
    @State var snapshotStore = SnapshotStore()

    /// Whether this pass has saved a snapshot that is still on disk, so resuming or
    /// finishing knows there is one to remove.
    @State var hasSavedSnapshot = false

    /// Set once the pass has been saved to finish later, so closing doesn't also save it
    /// as a finished run — it stays in progress until it is carried on.
    @State var savedForLater = false
    @State var showSaveForLaterFailed = false

    /// Why the video of a saved pass couldn't be opened, while that is being said.
    @State var missingVideo: VideoLibrary.LookupFailure?
    @State var truth: GroundTruthDocument?

    /// Identity of the analysis pass in progress, so repeated saves update one run.
    @State var currentRunID: UUID?

    /// Recorded frames of player positions last written, so saving the run again doesn't
    /// rewrite an unchanged file.
    @State var savedPositionFrames = 0

    /// What the wrap-up after a pass is doing, while it runs. Nil the rest of the time.
    @State var finishingStep: String?

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

    /// How many people are on court, picked on the start card. Nil leaves players as
    /// tracks, without identities.
    @State var gameFormat: GameFormat?

    /// When the pass started, for the rate the progress view reports.
    @State var analysisStartedAt: Date?

    /// Length of the clip, for progress. Zero until it loads.
    @State var clipDuration: Double = 0

    /// Whether the blocked-area editor is up, drawn on the frame on screen.
    @State var showZoneEditor = false

    /// Asked before leaving a pass that hasn't finished, since the frames it never
    /// reached are frames nothing knows about.
    @State var showDismissConfirmation = false
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
                    // One bottom bar rather than three overlays pinned to the same
                    // edge: with the blocking button spelled out, a leading group and a
                    // centred group landed on top of each other.
                    .overlay(alignment: .bottom) { bottomControls(videoProcessor) }
                    .overlay {
                        if !hasStartedAnalysis {
                            AnalysisStartCard(
                                clipDuration: clipDuration,
                                hasRim: videoProcessor.tracker.gameState.rim != nil,
                                format: $gameFormat,
                                onWatch: { startAnalysis(watching: true) },
                                // Kept wired up though the card no longer offers it —
                                // see `AnalysisStartCard.runWithoutWatchingChoice`.
                                onRunWithoutWatching: { startAnalysis(watching: false) }
                            )
                        }
                    }
                }
            }
            
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button {
                // Nothing to warn about when there is nothing half-done.
                if isAnalysisUnfinished {
                    showDismissConfirmation = true
                } else {
                    close()
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.chromeCircle)
            .padding(8)
        }
        // Deliberately does not pause the pass: if the answer is "keep analysing", the
        // seconds spent deciding shouldn't have been wasted.
        .alert("Stop analysing?", isPresented: $showDismissConfirmation) {
            Button("Keep analysing", role: .cancel) { }
            Button("Save and complete later") { saveForLater() }
            Button("Stop and save", role: .destructive) {
                // Stopped first, so no frame is moving the identities on while they are
                // re-solved.
                videoProcessor?.pause(.userInitiated)
                finishAnalysis { close() }
            }
        } message: {
            Text(dismissWarning)
        }
        .sheet(isPresented: $showLibrary) {
            VideoPicker(
                isPresented: $showLibrary,
                // The picker hands back a file; a saved pass comes back as whatever Photos
                // gives, so `asset` is the broader type.
                selectedAsset: Binding(get: { asset as? AVURLAsset }, set: { asset = $0 }),
                assetIdentifier: $assetIdentifier,
                assetState: $assetState
            )
        }
        .onAppear(perform: {
            // TEMP-NOLIB
            if asset == nil, continuing == nil { showLibrary = true }
        })
        .task { await openSavedPass() }
        .task(id: asset) {
            guard let asset else { return }

            if let continuing {
                await carryOn(continuing, with: asset)
                return
            }

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
                    capturedAt = await VideoLibrary.captureDate(for: assetIdentifier, asset: asset)

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
        .alert(
            "Couldn't find the video",
            isPresented: Binding(get: { missingVideo != nil }, set: { if !$0 { missingVideo = nil } })
        ) {
            Button("Delete Saved Analysis", role: .destructive) {
                snapshotStore.delete()
                dismiss()
            }
            Button("Keep It", role: .cancel) { dismiss() }
        } message: {
            Text(missingVideoMessage)
        }
        .alert("Couldn't save for later", isPresented: $showSaveForLaterFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The analysis is still here. Carry on, or stop and save what's been found so far.")
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
        // The reader has run out of frames: the numbers are final, so save them and hand
        // the user the reviewable version of the clip.
        .onChange(of: videoProcessor?.isComplete ?? false) { _, finished in
            guard finished, let videoProcessor else { return }
            finishAnalysis {
                videoProcessor.tracker.gameState.setPlayerRecords(
                    possession: videoProcessor.tracker.possession,
                    identities: videoProcessor.tracker.identities,
                    positions: videoProcessor.tracker.positions
                )
                showAnalysisReview = true
            }
        }
        .fullScreenCover(isPresented: $showAnalysisReview) {
            if let videoProcessor, let asset {
                AnalysisReviewView(
                    gameState: videoProcessor.tracker.gameState,
                    asset: asset,
                    orientedVideoSize: videoProcessor.orientedVideoSize,
                    onDismiss: { showAnalysisReview = false },
                    frameProvider: frameProvider,
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
        .overlay {
            if let finishingStep {
                FinishingAnalysisOverlay(step: finishingStep)
            }
        }
        .keepsScreenAwake(isAnalysing)
        .onChange(of: scenePhase) { _, phase in
            // Only a pass that has been started has anything to hold or pick up again.
            guard hasStartedAnalysis, let videoProcessor else { return }

            switch ScenePause.action(
                isActive: phase == .active,
                playback: videoProcessor.playback,
                reason: videoProcessor.pauseReason
            ) {
            case .pause: videoProcessor.pause(.systemTriggered)
            case .resume: resume(videoProcessor)
            case .none: break
            }

            // The app can be suspended from here, and ended while suspended without a
            // word, so this is the last moment to keep what the pass has learnt.
            if phase == .background { saveSnapshot(of: videoProcessor) }
        }
        .onDisappear {
            // A pass saved to finish later isn't finished: it stays as the analysis in
            // progress, not a run on the dashboard.
            if !savedForLater { saveRun() }
        }
    }

    /// Whether frames are being worked through, or the pass is being wrapped up. Locking
    /// mid-way would send the app to the background, where neither can carry on. A pass
    /// the user paused can lock like anything else.
    var isAnalysing: Bool {
        finishingStep != nil || (hasStartedAnalysis && videoProcessor?.playback == .resume)
    }

    /// The controls along the bottom of the analysis view.
    ///
    /// `ViewThatFits` picks the single row when there is width for it and stacks the two
    /// groups when there isn't — which covers the narrow phones, landscape, and a large
    /// Dynamic Type setting without a width calculation that would be wrong on one of
    /// them.
    @ViewBuilder
    func bottomControls(_ videoProcessor: VideoProcessor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                frameTools(videoProcessor)
                Spacer(minLength: 12)
                transportControls(videoProcessor)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    frameTools(videoProcessor)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    transportControls(videoProcessor)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom)
        .chromeBarBackground()
    }

    /// What can be corrected about the frame itself. Both need the picture, so both go
    /// when the preview does.
    @ViewBuilder
    func frameTools(_ videoProcessor: VideoProcessor) -> some View {
        if showsPreview {
            Button {
                showRimPlacement = true
            } label: {
                Label("Rim", systemImage: "scope")
            }
            .buttonStyle(.chromeChip)

            // Watching is when a bin or a sign being read as the ball is actually
            // noticed, so the fix is offered right here — spelled out, because a bare
            // "no entry" glyph doesn't say what it would do to the analysis.
            Button {
                withAnimation { videoProcessor.pause(.userInitiated) }
                showZoneEditor = true
            } label: {
                Label(blockedAreasLabel, systemImage: "nosign")
            }
            .buttonStyle(
                .chromeChip(
                    tint: truth?.exclusions.isEmpty == false
                        ? .red.opacity(0.3)
                        : .white.opacity(0.14)
                )
            )
        }
    }

    /// Not currently shown — see `transportControls`.
    ///
    /// Hiding the preview mid-pass makes the analysis quicker, but while a single video
    /// is the only thing being analysed there is nothing to spend that time on: the user
    /// is sat watching a progress bar either way. It earns its place the moment there is
    /// somewhere else to be — a queue, or several videos analysed at once — so it is
    /// parked here rather than deleted.
    ///
    /// Everything behind it still works: `setPreview(_:)` is what the start card's
    /// "Analyse without watching" calls, and the progress panel offers the way back.
    @ViewBuilder
    func previewToggle() -> some View {
        Button {
            setPreview(!showsPreview)
        } label: {
            Image(systemName: showsPreview ? "eye.slash" : "eye")
        }
        .buttonStyle(.chromeGlyph)
        .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    func transportControls(_ videoProcessor: VideoProcessor) -> some View {
        if hasStartedAnalysis {
            Button {
                togglePlayback(videoProcessor)
            } label: {
                Image(systemName: videoProcessor.playback == .pause ? "play.circle.fill" : "pause.circle.fill")
            }
            .buttonStyle(.chromeGlyph(size: 42))
            .contentTransition(.symbolEffect(.replace))

        }

    }

    var blockedAreasLabel: String {
        let count = truth?.exclusions.count ?? 0
        return count == 0 ? "Block area" : "Blocked \(count)"
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
        videoProcessor.tracker.setFormat(gameFormat)
        setPreview(watching)
        resume(videoProcessor)
    }

    func togglePlayback(_ videoProcessor: VideoProcessor) {
        if videoProcessor.playback == .pause {
            resume(videoProcessor)
        } else {
            withAnimation { videoProcessor.pause(.userInitiated) }
        }
    }

    func setPreview(_ isOn: Bool) {
        showsPreview = isOn
        videoProcessor?.producesPreviewFrames = isOn
    }

    func resume(_ videoProcessor: VideoProcessor) {
        // Carrying on from memory: what was saved for a restart is now behind.
        discardSnapshot()

        // The clock starts at the first resume and keeps running across pauses, so the
        // rate shown is the rate of the whole pass rather than of the last burst.
        if analysisStartedAt == nil { analysisStartedAt = Date() }

        withAnimation { videoProcessor.resume() }

        Task.detached(priority: .userInitiated) {
            await videoProcessor.play()
        }
    }


    /// Save what the pass has learnt so far, in case iOS ends the app before it comes
    /// back. Only for a pass that has started and isn't finished or being wrapped up.
    ///
    /// Gathered on the main thread once the frame loop has stopped, then compressed and
    /// written off it — inside a background task, since the app is on its way out.
    func saveSnapshot(of videoProcessor: VideoProcessor) {
        guard hasStartedAnalysis, finishingStep == nil, !videoProcessor.isComplete,
              let assetIdentifier else { return }

        let window = BackgroundTaskWindow(name: "Save analysis in progress")
        let snapshotStore = snapshotStore
        Task {
            defer { window.end() }

            guard let snapshot = await AnalysisSnapshot.capture(
                from: videoProcessor,
                assetIdentifier: assetIdentifier,
                runID: currentRunID,
                capturedAt: capturedAt,
                clipSeconds: clipDuration
            ) else { return }

            let saved = await Task.detached(priority: .userInitiated) {
                (try? snapshotStore.save(snapshot)) != nil
            }.value
            if saved { hasSavedSnapshot = true }
        }
    }

    /// Save the pass to finish later, then leave for the dashboard, where it shows as the
    /// analysis in progress. Stays put and says so if it couldn't be saved — closing then
    /// would lose the pass without a word.
    func saveForLater() {
        guard let videoProcessor, let assetIdentifier else { return }

        videoProcessor.pause(.userInitiated)
        finishingStep = "Saving for later…"

        let snapshotStore = snapshotStore
        Task {
            var saved = false
            if let snapshot = await AnalysisSnapshot.capture(
                from: videoProcessor,
                assetIdentifier: assetIdentifier,
                runID: currentRunID,
                capturedAt: capturedAt,
                clipSeconds: clipDuration
            ) {
                saved = await Task.detached(priority: .userInitiated) {
                    (try? snapshotStore.save(snapshot)) != nil
                }.value
            }

            finishingStep = nil
            guard saved else {
                showSaveForLaterFailed = true
                return
            }

            hasSavedSnapshot = true
            savedForLater = true
            dismiss()
            navigation?.showInProgressAnalysis()
        }
    }

    /// For a saved pass: find its video in Photos. Setting `asset` carries on from there.
    func openSavedPass() async {
        guard let continuing, asset == nil else { return }

        assetIdentifier = continuing.assetIdentifier
        assetState = .loading
        do {
            asset = try await VideoLibrary.asset(for: continuing.assetIdentifier)
        } catch let failure as VideoLibrary.LookupFailure {
            missingVideo = failure
        } catch {
            missingVideo = .assetMissing
        }
    }

    /// Rebuild a saved pass and set it running again: no pre-flight scan, since the rim is
    /// in what was saved, and no start card, since the format is too.
    func carryOn(_ snapshot: AnalysisSnapshot, with asset: AVAsset) async {
        assetState = .processing
        do {
            let processor = try await snapshot.makeProcessor(asset: asset)
            videoProcessor = processor
            frameProvider = ShotFrameProvider(asset: asset)

            clipDuration = snapshot.clipSeconds
            capturedAt = snapshot.capturedAt
            currentRunID = snapshot.runID
            gameFormat = snapshot.tracker.identity?.record.format

            // What the user has told us about the video, as on any pass. The rim isn't
            // set from it: the saved pass already has the rim it was judging against.
            let assetIdentifier = snapshot.assetIdentifier
            let stored = store.loadTruth(for: assetIdentifier)
            truth = stored
            plan = store.loadPlan(for: assetIdentifier)
            processor.tracker.setExclusionZones(stored.exclusions)
            processor.tracker.gameState.applyStoredTruth(stored.shots)
            processor.tracker.gameState.onVerdictChanged = { [assetIdentifier] attempt in
                recordVerdict(for: attempt, assetIdentifier: assetIdentifier)
            }

            // The file is this pass's now: resuming removes it, and leaving again saves
            // a new one.
            hasSavedSnapshot = true
            hasStartedAnalysis = true
            assetState = .ready
            resume(processor)
        } catch {
            assetState = .failed
            print("error \(error.localizedDescription)")
        }
    }

    var missingVideoMessage: String {
        switch missingVideo {
        case .notAuthorized:
            return "Scoreboard can't see your videos. Allow access in Settings to carry on this analysis."
        default:
            return "It may have been removed from this device, or be in iCloud and not available right now."
        }
    }

    /// Remove the saved snapshot, when this pass made one.
    func discardSnapshot() {
        guard hasSavedSnapshot else { return }
        hasSavedSnapshot = false

        let snapshotStore = snapshotStore
        Task.detached(priority: .utility) { snapshotStore.delete() }
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
    /// Leave the analysis. If a run was saved, go to its game on the dashboard.
    func close() {
        dismiss()

        guard currentRunID != nil, let assetIdentifier else { return }
        navigation?.showSavedGame(assetIdentifier)
    }

    /// Wrap up a pass — re-solve identities with the whole clip, then save — behind an
    /// overlay, off the main thread, then carry on with `next`.
    ///
    /// Both can take seconds on a long clip. Run on the main thread they froze the screen
    /// with nothing to say why, then closed it all at once.
    func finishAnalysis(then next: @escaping () -> Void) {
        guard let videoProcessor else {
            next()
            return
        }

        // Finishing either way, so there is nothing left to carry on.
        discardSnapshot()

        finishingStep = "Re-checking who's who…"
        Task {
            // Before saving, so the run keeps identities corrected with the whole clip.
            await videoProcessor.tracker.finishIdentities()

            finishingStep = "Saving…"
            if let pending = pendingSave() {
                let store = store
                await Task.detached(priority: .userInitiated) {
                    Self.write(pending, to: store)
                }.value
                savedPositionFrames = pending.positions?.frames.count ?? savedPositionFrames
            }

            finishingStep = nil
            next()
        }
    }

    /// Everything a save writes, gathered on the main thread so the writing can happen
    /// off it.
    struct PendingSave {
        let run: AnalysisRun
        let positions: PlayerPositionRecord?
        let attempts: [ShotAttempt]
        let capturedAt: Date?
    }

    func saveRun() {
        guard let pending = pendingSave() else { return }
        Self.write(pending, to: store)
        savedPositionFrames = pending.positions?.frames.count ?? savedPositionFrames
    }

    /// What saving now would write, or nil when there's nothing to save.
    func pendingSave() -> PendingSave? {
        guard let assetIdentifier, let videoProcessor else { return nil }

        let gameState = videoProcessor.tracker.gameState
        let attempts = gameState.reviewableAttempts
        guard !attempts.isEmpty else { return nil }

        // One run id per analysis pass, so repeated saves during a session update the
        // same run rather than piling up near-identical copies.
        let id = currentRunID ?? UUID()
        currentRunID = id

        let run = AnalysisRun(
            id: id,
            assetIdentifier: assetIdentifier,
            configuration: videoProcessor.tracker.currentConfiguration(),
            attempts: attempts,
            ballStats: videoProcessor.tracker.ballDetector?.stats,
            playerStats: videoProcessor.tracker.playerStats,
            possession: videoProcessor.tracker.possession,
            identities: videoProcessor.tracker.identities
        )

        // Large, and only for replay: written beside the run, and only when there's more
        // of it than last time — a run is saved again for every merged shot.
        let positions = videoProcessor.tracker.positions
        return PendingSave(
            run: run,
            positions: positions.frames.count != savedPositionFrames ? positions : nil,
            attempts: attempts,
            capturedAt: capturedAt
        )
    }

    /// Writes a save. Not tied to the main thread, so the finishing step can do it in the
    /// background.
    nonisolated static func write(_ pending: PendingSave, to store: ShotStore) {
        let run = pending.run
        try? store.saveRun(run)

        if let positions = pending.positions {
            try? store.savePositions(positions, for: run.assetIdentifier, runID: run.id)
        }

        // The library list reads summaries rather than parsing every run.
        try? store.refreshSummary(
            for: run.assetIdentifier,
            attempts: pending.attempts,
            capturedAt: pending.capturedAt
        )
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

    /// Whether leaving now would abandon frames that have never been looked at.
    ///
    /// A pass that finished, or never started, has nothing to lose by closing.
    var isAnalysisUnfinished: Bool {
        guard hasStartedAnalysis, let videoProcessor else { return false }
        return !videoProcessor.isComplete
    }

    /// What leaving early costs, in the terms the user can see on screen.
    ///
    /// Worth spelling out because the result looks complete either way: a timeline of
    /// shots with totals above it, which says nothing about the half of the video the
    /// detector never reached.
    ///
    /// When several videos can be queued this becomes the wrong question — leaving would
    /// mean "carry on in the background" rather than "stop" — and this goes with it.
    var dismissWarning: String {
        guard let videoProcessor else { return "The rest of the video hasn't been analysed." }

        let progress = progress(for: videoProcessor)
        let found = videoProcessor.tracker.gameState.reviewableAttempts.count

        let reached = clipDuration > 0
            ? "Only the first \(ShotScrubber.timecode(progress.analysedSeconds)) of \(ShotScrubber.timecode(progress.clipSeconds)) has been analysed. "
            : "The video hasn't been analysed all the way through. "

        // Nothing is written for a pass that found nothing — `saveRun` skips an empty
        // run — so the zero case mustn't promise anything was kept.
        switch found {
        case 0:
            return reached + "No shots have been found yet, and anything later in the video won't be analysed — analysing again starts from the beginning."
        case 1:
            return reached + "The shot found so far is saved, but anything later in the video won't be — analysing again starts from the beginning."
        default:
            return reached + "The \(found) shots found so far are saved, but anything later in the video won't be — analysing again starts from the beginning."
        }
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

