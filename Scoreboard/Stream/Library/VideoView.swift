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

    /// Shown the moment the last frame has been analysed. The processing view is a tuning
    /// instrument; this is what the result is actually for.
    @State var showAnalysisReview = false
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
                    currentFrame
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            GeometryReader { geometry in
                                ForEach(videoProcessor.tracker.rects) { rectData in
                                    let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                                    Rectangle()
                                        .stroke(rectData.colour, lineWidth: 2)
                                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                                        .position(x: adjustedRect.midX, y: adjustedRect.midY)

                                    Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                                        .foregroundColor(.red)
                                }
                                ForEach(videoProcessor.tracker.trackedRects) { rectData in
                                    let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                                    Rectangle()
                                        .stroke(rectData.colour, lineWidth: 2)
                                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                                        .position(x: adjustedRect.midX, y: adjustedRect.midY)
                                    
                                    Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                                        .foregroundColor(.red)
                                }
                                let gameState = videoProcessor.tracker.gameState

                                // The ball is detected rather than tracked, so it is
                                // drawn from its own sighting instead of the track list.
                                if let ball = videoProcessor.tracker.ballRect {
                                    let adjusted = adjustRectForView(rect: ball.rect, viewSize: geometry.size)
                                    Rectangle()
                                        .stroke(ball.colour, lineWidth: 2)
                                        .frame(width: adjusted.width, height: adjusted.height)
                                        .position(x: adjusted.midX, y: adjusted.midY)
                                }

                                // Live ball position. `center` is a true centre now, so
                                // the circle is built symmetrically around it.
                                if let currentBall = gameState.ballHistory.last {
                                    let ballRect = CGRect(
                                        x: currentBall.center.x - currentBall.radius,
                                        y: currentBall.center.y - currentBall.radius,
                                        width: currentBall.radius * 2,
                                        height: currentBall.radius * 2
                                    )
                                    let adjustedRect = adjustRectForView(rect: ballRect, viewSize: geometry.size)
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                                        .position(x: adjustedRect.midX, y: adjustedRect.midY)
                                }

                                // Fitted arc, drawn only while a shot is live.
                                if !gameState.arcPoints.isEmpty {
                                    Path { path in
                                        let points = gameState.arcPoints.map {
                                            normalizedToView($0, viewSize: geometry.size)
                                        }
                                        guard let first = points.first else { return }
                                        path.move(to: first)
                                        for point in points.dropFirst() {
                                            path.addLine(to: point)
                                        }
                                    }
                                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                }

                                // The scoring plane the make/miss verdict is measured against.
                                if let hoopGeometry = gameState.rim {
                                    let ellipseRect = adjustedEllipseFrame(
                                        center: hoopGeometry.center,
                                        radiusX: hoopGeometry.horizontalRadius,
                                        radiusY: hoopGeometry.verticalRadius,
                                        viewSize: geometry.size
                                    )

                                    Path { path in
                                        path.addEllipse(in: ellipseRect)
                                    }
                                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                                    Path { path in
                                        let y = (1 - hoopGeometry.scoringPlaneY) * geometry.size.height
                                        path.move(to: CGPoint(x: hoopGeometry.leftX * geometry.size.width, y: y))
                                        path.addLine(to: CGPoint(x: hoopGeometry.rightX * geometry.size.width, y: y))
                                    }
                                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                                }

                                LiveShotReadout(gameState: gameState)
                                    .position(x: geometry.size.width / 2, y: 40)

                                if let hoop = videoProcessor.tracker.hoop.first {
                                    let adjustedRect = adjustRectForView(rect: hoop.rect, viewSize: geometry.size)
                                    Rectangle()
                                        .stroke(hoop.colour, lineWidth: 2)
                                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                                        .position(x: adjustedRect.midX, y: adjustedRect.midY)
//                                    Text("\(hoop.label) \(hoop.id)")
//                                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
//                                        .foregroundColor(.red)
                                    Text("\(hoop.label) (\(Int(hoop.confidence * 100))%)")
                                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .overlay(alignment: .top) {
                            if videoProcessor.tracker.gameState.rim == nil {
                                RimMissingBanner {
                                    showRimPlacement = true
                                }
                                .padding(.top, 60)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            Button {
                                showRimPlacement = true
                            } label: {
                                Label("Rim", systemImage: "scope")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .padding()
                        }
                        .overlay(alignment: .bottom, content: {
                            HStack {
                                Spacer()
                                if #available(iOS 26.0, *) {
                                    Button {
                                        showHistory.toggle()
                                    } label: {
                                        Image(systemName: "list.clipboard")
                                    }
                                    .buttonStyle(.glass)
                                    .padding()
                                    
                                } else {
                                    Button {
                                        showHistory.toggle()
                                    } label: {
                                        Image(systemName: "list.clipboard")
                                    }
                                    .buttonStyle(.bordered)
                                    .padding()
                                }
                            }
                        })
                        .overlay(alignment: .bottom) {
                            HStack {
                                if #available(iOS 26.0, *) {
                                    Button {
                                        if videoProcessor.playback == .pause {
                                            withAnimation {
                                                videoProcessor.playback = .resume
                                            }
                                            Task.detached(priority: .userInitiated) {
                                                await videoProcessor.play()
                                            }
                                        } else {
                                            withAnimation {
                                                videoProcessor.playback = .pause
                                            }
                                        }
                                    } label: {
                                        Image(systemName: videoProcessor.playback == PlaybackState.pause ? "play.fill" : "pause.fill")
                                    }
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.circle)
                                    .contentTransition(.symbolEffect(.replace))
                                    .padding(.bottom)
                                } else {
                                    Button {
                                        if videoProcessor.playback == .pause {
                                            withAnimation {
                                                videoProcessor.playback = .resume
                                            }
                                            Task.detached(priority: .userInitiated) {
                                                await videoProcessor.play()
                                            }
                                        } else {
                                            withAnimation {
                                                videoProcessor.playback = .pause
                                            }
                                        }
                                    } label: {
                                        Image(systemName: videoProcessor.playback == PlaybackState.pause ? "play.fill" : "pause.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.circle)
                                    .contentTransition(.symbolEffect(.replace))
                                    .padding(.bottom)
                                }
                                
                                if #available(iOS 26.0, *) {
                                    Button {
                                        Task {
                                            await videoProcessor.next()
                                        }
                                    } label: {
                                        Text("next")
                                    }
                                    .buttonStyle(.glass)
                                    .padding(.bottom)
                                } else {
                                    Button {
                                        Task {
                                            await videoProcessor.next()
                                        }
                                    } label: {
                                        Text("next")
                                    }
                                    .buttonStyle(.bordered)
                                    .padding(.bottom)
                                }
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
                    ballStats: videoProcessor.tracker.ballDetector?.stats
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

    /// Normalized Vision point (origin bottom-left, y up) to SwiftUI view point.
    func normalizedToView(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * viewSize.width, y: (1 - point.y) * viewSize.height)
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

    func saveRim(_ geometry: HoopGeometry) {
        guard let assetIdentifier else { return }

        var document = truth ?? GroundTruthDocument(assetIdentifier: assetIdentifier)
        document.rim = geometry

        truth = document
        try? store.saveTruth(document)
    }

    func adjustRectForView(rect: CGRect, viewSize: CGSize) -> CGRect {
        
        let width = rect.width * viewSize.width
        let height = rect.height * viewSize.height
        
        let x = rect.origin.x * viewSize.width
        let y = (1 - rect.origin.y - rect.height) * viewSize.height
        return CGRect(x: x, y: y, width: width, height: height)
        
//        let scale = CGAffineTransform.identity.scaledBy(x: viewSize.width, y: viewSize.height)
//        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -viewSize.height)
//        return rect.applying(scale).applying(transform)
    }
    
    // Adjust a normalized ellipse (center in 0..1 space, radii normalized) to view coordinates, returning a CGRect centered at the correct point.
    // Rotation, if needed, should be applied by the caller as a transform to a path.
    func adjustedEllipseFrame(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, viewSize: CGSize) -> CGRect {
        let cx = center.x * viewSize.width
        let cy = (1 - center.y) * viewSize.height // flip Y to match image space used elsewhere
        let rx = radiusX * viewSize.width
        let ry = radiusY * viewSize.height
        return CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
    }
}

//#Preview {
//    VideoView(video: )
//}

