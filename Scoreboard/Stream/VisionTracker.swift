//
//  VisionTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 15/11/2025.
//

import Foundation
import Vision
import SwiftUI

@Observable
class VisionTracker {

    // Frame identification
    // Monotonic index of frames processed by VisionTracker, advanced by `beginFrame()`.
    // This is the single time base for the trajectory fit — it must count video frames,
    // not milliseconds, because the ballistic thresholds are expressed per frame.
    private(set) var frameCounter: Int = 0

    // Object detection
    var visionModel: VNCoreMLModel?
    var hoop: [RectangleData] = []

    /// Most recent ball sighting, drawn separately from the players.
    var ballRect: RectangleData?

    /// Players to draw: confirmed and coasting tracks, as of the latest frame. Only
    /// published while an overlay is being drawn.
    var playerTracks: [PlayerTrack] = []

    /// Main-actor game state for the UI to read.
    let gameState = GameState()

    /// Shot detection engine. Runs on the frame-processing thread; results are handed
    /// to `gameState` on the main actor.
    let shotTracker = ShotTracker()

    /// Finds the ball by re-detecting inside a moving crop each frame — see
    /// `BallDetector`.
    private(set) var ballDetector: BallDetector?

    /// Follows the players between detection passes — see `PlayerTracker`.
    @ObservationIgnored private(set) var playerTracker = PlayerTracker()

    /// Detection numbers gathered on every frame with full-frame results. Read through
    /// `playerStats`, which adds the tracker's lifetimes.
    @ObservationIgnored private var playerDetectionStats = PlayerDetectionStats(
        passInterval: PlayerTracker.Config().detectionInterval
    )
    @ObservationIgnored private var previousPlayerSample: PlayerSample?

    /// Frame the rim was last sampled on.
    @ObservationIgnored private var lastRimSampleFrame: Int?

    /// Frames between rim samples — about a second at 30 fps.
    ///
    /// Player passes run every few frames, and every one of them sees the rim. Feeding
    /// them all would fill the rim's 31-sample window from the opening seconds, which is
    /// exactly when it is most often screened by players. Spacing the samples spreads the
    /// window across the clip instead.
    static let rimSampleInterval = 30

    /// Whether anything is drawing the overlay. See `setOverlayUpdates(_:)`.
    @ObservationIgnored private var publishesOverlay = true

    /// Zones kept from before the model finished loading, which is when the ball detector
    /// is built. Without this, zones set during setup would reach the tracker but not the
    /// detector, and a decoy could still pull the moving crop onto itself.
    private var pendingExclusionZones: [ExclusionZone] = []

    init() {
        print("DEBUG: TRACKER CREATED")

        setOverlayUpdates(true)

        shotTracker.onEvent = { [gameState] event in
            Task { @MainActor in
                gameState.handle(event)
            }
        }

        Task {
            await visionModel = try ObjectDetector.createDetector()
            if let visionModel {
                ballDetector = BallDetector(model: visionModel)
                ballDetector?.exclusionZones = pendingExclusionZones
            }
        }
    }

    deinit {
        print("DEBUG: TRACKER DESTROYED")
    }

    /// Whether per-frame overlay updates are published.
    ///
    /// Each update is a hop to the main actor, and the only thing that reads one is an
    /// overlay drawn over the frames. A pass nobody is watching has no use for them, so
    /// it turns them off — and back on if the user decides to watch after all.
    func setOverlayUpdates(_ enabled: Bool) {
        publishesOverlay = enabled

        shotTracker.onSnapshot = enabled
            ? { [gameState] snapshot in
                Task { @MainActor in
                    gameState.apply(snapshot)
                }
            }
            : nil
    }

    func clear() {
        shotTracker.endOfStream(atFrame: frameCounter)
    }

    /// Open a new video frame. Must be called exactly once per frame, before running
    /// detection on it.
    ///
    /// The frame index used to live inside the tracking step, which meant frames that
    /// only ran detection never advanced it — several observations would share a frame
    /// ID and collapse the trajectory fit's time axis.
    /// - Parameter timeSeconds: presentation time of this frame. Optional because the
    ///   frame index alone is enough to detect shots; the timestamp is what makes them
    ///   seekable afterwards.
    func beginFrame(timeSeconds: Double? = nil) {
        frameCounter &+= 1

        // Committing the previous frame's sighting is where the shot detector runs.
        PipelineSignpost.measure("Shot tracking") {
            shotTracker.beginFrame(frameCounter, timeSeconds: timeSeconds)
        }
    }

    /// Run this frame's detection and move every tracked object on.
    ///
    /// The ball pass runs every frame. When the player tracker is due a detection pass,
    /// a full-frame request joins it on the same handler — a handler converts and scales
    /// the frame once for everything performed on it, where separate handlers each redo
    /// that work (~9 ms per extra pass on an iPhone 15 Plus). When the ball pass is
    /// already sweeping the whole frame, its results stand in for the player pass.
    ///
    /// Must be called once per frame, after `beginFrame()`.
    func detect(pixelBuffer: CVImageBuffer, orientation: CGImagePropertyOrientation) {
        guard let ballDetector, let visionModel else { return }

        let ballPass = ballDetector.makePass(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            frameID: frameCounter,
            history: shotTracker.ballHistory,
            fit: shotTracker.currentFit
        )

        let playerRequest = playerTracker.isDetectionDue(frameID: frameCounter) && !ballPass.isSweep
            ? Self.fullFrameRequest(model: visionModel)
            : nil

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try PipelineSignpost.measure(playerRequest == nil ? "Detect: ball" : "Detect: ball + players") {
                try handler.perform([ballPass.request] + (playerRequest.map { [$0] } ?? []))
            }
        } catch {
            // Each request keeps whatever results it got, so carry on with those rather
            // than losing the frame.
            print("Detection failed: \(error)")
        }

        let found = ballDetector.finish(ballPass)

        // The whole frame's results, when this frame has them: the player pass, or the
        // ball detector's sweep, which saw the players and the rim along with the ball.
        let fullFrame: (results: [VNRecognizedObjectObservation], source: PlayerDetectionStats.Source)? =
            if let playerRequest {
                (playerRequest.results as? [VNRecognizedObjectObservation] ?? [], .pass)
            } else if ballPass.isSweep {
                (ballPass.request.results as? [VNRecognizedObjectObservation] ?? [], .sweep)
            } else {
                nil
            }

        trackPlayers(fullFrame.map { (PlayerDetection.players(in: $0.results), $0.source) })

        if let fullFrame {
            sampleRim(from: fullFrame.results)
        }

        guard let found else { return }

        shotTracker.ingestBall(
            boundingBox: found.boundingBox,
            confidence: CGFloat(found.confidence),
            frameID: frameCounter
        )

        Task { @MainActor in
            self.ballRect = RectangleData(
                id: UUID(),
                rect: found.boundingBox,
                label: "Ball",
                confidence: found.confidence,
                colour: .orange
            )
        }
    }

    /// Detection and tracking numbers for the run so far, for saving with it.
    var playerStats: PlayerDetectionStats {
        var stats = playerDetectionStats

        // Tracks still running count with the lifetime they have reached so far:
        // otherwise a clip whose players never leave shot would report no lifetimes.
        let live = playerTracker.visibleTracks
        stats.tracking = PlayerDetectionStats.TrackingSummary(
            config: playerTracker.config,
            tracksConfirmed: playerTracker.tracksConfirmed,
            confirmedTrackFrames: playerTracker.endedTrackFrames
                + live.reduce(0) { $0 + $1.lastSeenFrame - $1.firstFrame }
        )
        return stats
    }

    // MARK: Players

    /// Move the players on to this frame, folding in `detections` when it had any.
    private func trackPlayers(_ detections: (players: [PlayerDetection], source: PlayerDetectionStats.Source)?) {
        PipelineSignpost.measure("Player tracking") {
            playerTracker.update(frameID: frameCounter, detections: detections?.players)
        }

        let visible = playerTracker.visibleTracks

        if let detections {
            previousPlayerSample = playerDetectionStats.record(
                frameID: frameCounter,
                detections: detections.players,
                previous: previousPlayerSample,
                trackedPlayers: visible.count,
                source: detections.source
            )
        }

        guard publishesOverlay else { return }
        Task { @MainActor in
            self.playerTracks = visible
        }
    }

    /// A request for the whole frame, every class.
    private static func fullFrameRequest(model: VNCoreMLModel) -> VNCoreMLRequest {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        return request
    }

    // MARK: Rim

    /// Offer the rim tracker the most confident rim in a full-frame result, at most once
    /// every `rimSampleInterval` frames.
    private func sampleRim(from results: [VNRecognizedObjectObservation]) {
        guard !shotTracker.isRimUserPlaced else { return }
        if let lastRimSampleFrame, frameCounter - lastRimSampleFrame < Self.rimSampleInterval {
            return
        }

        // A lower bar until the rim has settled: it is static, so a run of middling
        // detections still medians into a good estimate.
        let threshold: Float = shotTracker.isRimLocked ? 0.6 : 0.5

        guard let rim = results
            .filter({ $0.labels.first?.identifier == ObjectType.rim.rawValue && $0.confidence > threshold })
            .max(by: { $0.confidence < $1.confidence })
        else { return }

        lastRimSampleFrame = frameCounter

        // The rim is static, so every detection is another sample of the same object
        // rather than a replacement for it. ShotTracker takes the running median so the
        // scoring plane doesn't wobble under an in-flight shot.
        shotTracker.ingestRim(boundingBox: rim.boundingBox, frameID: frameCounter)

        guard publishesOverlay, let smoothed = shotTracker.rim else { return }
        Task { @MainActor in
            self.hoop = [
                RectangleData(
                    id: UUID(),
                    rect: smoothed.boundingBox,
                    label: ObjectType.rim.rawValue,
                    confidence: rim.confidence,
                    colour: .red)
            ]
        }
    }

    // MARK: Configuration

    /// How this tracker is currently configured, for recording with an analysis run.
    ///
    /// Assembled from the live objects rather than from defaults, so the record reflects
    /// what actually ran.
    func currentConfiguration() -> RunConfiguration {
        RunConfiguration(
            shotDetector: ShotDetectorConfig(),
            ballROI: ballDetector?.config ?? BallROIPredictor.Config(),
            fullFrameBallConfidence: Double(ballDetector?.fullFrameConfidence ?? 0.45),
            croppedBallConfidence: Double(ballDetector?.croppedConfidence ?? 0.25),
            modelIdentifier: ObjectDetector.modelIdentifier,
            rimSource: {
                guard shotTracker.rim != nil else { return .none }
                return shotTracker.isRimUserPlaced ? .userPlaced : .detected
            }()
        )
    }

    /// Pin the rim to a geometry the user placed by hand.
    func setUserRim(_ geometry: HoopGeometry) {
        shotTracker.setUserRim(geometry)
        shotTracker.refreshSnapshot(frameID: frameCounter)

        Task { @MainActor in
            self.hoop = [
                RectangleData(
                    id: UUID(),
                    rect: geometry.boundingBox,
                    label: "Rim (placed)",
                    confidence: 1.0,
                    colour: .orange)
            ]
        }
    }

    /// Blocked-out parts of the frame, applied to both the detector's candidate list and
    /// the tracker's commit point.
    func setExclusionZones(_ zones: [ExclusionZone]) {
        pendingExclusionZones = zones
        shotTracker.exclusionZones = zones
        ballDetector?.exclusionZones = zones
    }

    /// Seed the rim from a pre-flight scan of the clip.
    func seedRim(_ geometry: HoopGeometry) {
        shotTracker.seedRim(geometry)
        shotTracker.refreshSnapshot(frameID: frameCounter)
    }

    /// The model, once it has finished loading. Used by the pre-flight rim scan.
    func awaitVisionModel() async -> VNCoreMLModel? {
        for _ in 0..<50 {
            if let visionModel { return visionModel }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return visionModel
    }
}
