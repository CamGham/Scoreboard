//
//  AnalysisSnapshot.swift
//  Scoreboard
//
//  Created by Cam Graham on 10/11/2026.
//

import Foundation
import AVFoundation

/// An analysis part-way through, saved so it can be carried on after the app was closed.
///
/// Gathers what each part hands over — the tracker's state, which holds its own parts',
/// and the shots found so far — with where to pick up and the settings it ran with. It
/// never looks inside those states: a part that gains a field changes only its own.
struct AnalysisSnapshot: Codable, Equatable {

    /// Bumped whenever a saved state changes shape. A snapshot from another version is
    /// reported as one that can't be continued, rather than restored into code that would
    /// read it wrongly.
    static let currentFormatVersion = 1

    /// The last frame analysed, exactly — a `CMTime` as its parts, since that is what
    /// the reader is restarted from.
    struct ResumePoint: Codable, Equatable {
        var value: Int64
        var timescale: Int32

        /// The processor's own frame count, which carries on from here.
        var frames: Int

        init(time: CMTime, frames: Int) {
            value = time.value
            timescale = time.timescale
            self.frames = frames
        }

        var time: CMTime { CMTime(value: value, timescale: timescale) }
    }

    enum RestoreError: LocalizedError {
        case modelUnavailable

        var errorDescription: String? { "The detection model didn't load." }
    }

    var formatVersion = Self.currentFormatVersion
    var assetIdentifier: String

    /// The run this pass saves into, if it has saved one. Kept so finishing the pass
    /// updates that run rather than adding a second.
    var runID: UUID?

    var savedAt: Date

    /// When the video was recorded, for showing the pass in progress the way saved games
    /// are shown. Nil when Photos didn't say.
    var capturedAt: Date?

    /// The settings the pass started with. Carried on with these, so both halves of it
    /// are judged alike even if the defaults have changed since.
    var configuration: RunConfiguration

    var resumePoint: ResumePoint

    /// How far through the clip, for showing the pass in progress.
    var analysedSeconds: Double
    var clipSeconds: Double

    var tracker: VisionTracker.State
    var game: GameState.State

    // MARK: Capture

    /// Gather a snapshot of a pass that has been paused.
    ///
    /// Waits for the frame in hand to finish and for the shots it reported to reach the
    /// game state — but only so long, since this runs in the brief time the app gets as
    /// it goes to the background. Nil when the pass hasn't analysed a timed frame, or
    /// didn't settle in time.
    @MainActor
    static func capture(
        from processor: VideoProcessor,
        assetIdentifier: String,
        runID: UUID?,
        capturedAt: Date? = nil,
        clipSeconds: Double
    ) async -> AnalysisSnapshot? {
        let tracker = processor.tracker

        guard await settle(within: .seconds(2), until: { !processor.isLoopRunning }),
              await settle(within: .seconds(1), until: {
                  tracker.gameState.eventsHandled >= tracker.eventsSent
              }),
              let time = processor.lastFrameTime
        else { return nil }

        return AnalysisSnapshot(
            assetIdentifier: assetIdentifier,
            runID: runID,
            savedAt: Date(),
            capturedAt: capturedAt,
            configuration: tracker.configuration,
            resumePoint: ResumePoint(time: time, frames: processor.frames),
            analysedSeconds: time.seconds,
            clipSeconds: clipSeconds,
            tracker: tracker.snapshotState,
            game: tracker.gameState.snapshotState
        )
    }

    /// Wait for `condition`, checking every few milliseconds. False if it isn't true
    /// within `limit`.
    @MainActor
    private static func settle(within limit: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: Restore

    /// A processor for `asset` that carries on from here: built with the saved settings,
    /// reading from the frame after the last one analysed, with every part's state put
    /// back. Blocked areas and the user's rulings are about the video, not the pass, so
    /// the caller applies them as it does for any pass.
    @MainActor
    func makeProcessor(asset: AVAsset, producesPreviewFrames: Bool = true) async throws -> VideoProcessor {
        let processor = try await VideoProcessor.create(
            videoAsset: asset,
            producesPreviewFrames: producesPreviewFrames,
            configuration: configuration,
            resumingAfter: resumePoint.time
        )

        guard await processor.tracker.awaitVisionModel() != nil else {
            throw RestoreError.modelUnavailable
        }

        processor.tracker.restore(from: tracker)
        processor.tracker.gameState.restore(from: game)
        processor.frames = resumePoint.frames
        return processor
    }
}
