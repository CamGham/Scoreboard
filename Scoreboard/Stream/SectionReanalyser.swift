//
//  SectionReanalyser.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import Foundation
import AVFoundation
import Observation

/// Runs the detector again over marked sections of a clip, and hands each section's
/// results back to be merged.
///
/// The pass is the same one the full analysis uses — same tracker, same frame sequence —
/// restricted to a time range by the reader. Sharing the driver matters: a second frame
/// loop would be a second place for the "begin frame, detect ball, then predict or track"
/// order to drift, and a re-analysis that behaved subtly differently from the original
/// would make the two results incomparable, which is the whole point of re-running.
///
/// Two things are deliberately *not* the same as the first pass:
///
///  - The rim is pinned rather than detected. A short window may never show the rim
///    cleanly — the original pre-flight had the whole clip to find it — and without a
///    scoring plane the detector opens no attempts at all.
///  - No preview frames are decoded. Nobody is watching this pass; the picture on screen
///    belongs to the player.
@MainActor
@Observable
final class SectionReanalyser {

    /// What a whole run changed, for a sentence at the end of it.
    struct Summary: Equatable {
        var sections = 0
        var found = 0
        var removed = 0
    }

    enum Failure: LocalizedError {
        case modelUnavailable
        case readFailed

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "The detection model didn't load."
            case .readFailed: return "That part of the video couldn't be read."
            }
        }
    }

    private(set) var isRunning = false

    /// The section being worked on, and how far through it the reader has got, 0–1.
    private(set) var activeSection: ReanalysisSection?
    private(set) var progress: Double = 0

    private(set) var completedSections = 0
    private(set) var totalSections = 0

    /// Whether the pass is being drawn as it runs.
    ///
    /// The same trade as the first pass: watching is how you see *why* a window was
    /// wrong — a rim in the wrong place, a ball never picked up — and it costs a decoded
    /// frame and a redraw each time round.
    private(set) var isWatching = false

    /// The processor behind the section in progress. Held so a watching view has frames
    /// to draw; nil whenever nothing is running.
    private(set) var activeProcessor: VideoProcessor?

    /// Set once a run finishes, so the UI can report what happened.
    private(set) var summary: Summary?
    private(set) var failureMessage: String?

    /// Fraction of the whole run, across all sections — what a progress bar wants.
    var overallProgress: Double {
        guard totalSections > 0 else { return 0 }
        return (Double(completedSections) + progress) / Double(totalSections)
    }

    /// Start or stop watching, mid-pass. Only a matter of whether the next frame is
    /// drawn and whether the overlay is kept fed.
    func setWatching(_ isOn: Bool) {
        isWatching = isOn
        activeProcessor?.producesPreviewFrames = isOn
        activeProcessor?.tracker.setOverlayUpdates(isOn)
    }

    func clearResult() {
        summary = nil
        failureMessage = nil
    }

    /// Re-analyse each section in turn, merging as each one finishes.
    ///
    /// Merging per section rather than at the end means a run that fails halfway still
    /// leaves the sections it did finish improved, and the user watching the bar sees
    /// shots appear as they are found.
    ///
    /// - Parameters:
    ///   - rim: the scoring plane to judge against — from the original analysis, or the
    ///     one the user placed by hand.
    ///   - merge: called on the main actor with each section's results.
    ///   - onSectionFinished: called after a section has been merged, so its mark can be
    ///     cleared now that it has been looked at.
    func run(
        sections: [ReanalysisSection],
        asset: AVAsset,
        rim: HoopGeometry,
        exclusions: [ExclusionZone] = [],
        watching: Bool = false,
        merge: @MainActor (ReanalysisSection, [ShotAttempt]) -> GameState.MergeOutcome,
        onSectionFinished: @MainActor (ReanalysisSection) -> Void
    ) async {

        guard !isRunning, !sections.isEmpty else { return }

        isWatching = watching
        isRunning = true
        summary = nil
        failureMessage = nil
        totalSections = sections.count
        completedSections = 0

        // Counts what actually finished, not what was queued: a run that breaks on its
        // first section must not claim to have re-analysed the rest.
        var tally = Summary()

        for section in sections {
            activeSection = section
            progress = 0

            do {
                // Built first, then held, so a watching view has something to draw from
                // the moment the section starts rather than only once it ends.
                let processor = try await Self.makeProcessor(
                    asset: asset,
                    range: section.range,
                    rim: rim,
                    exclusions: exclusions,
                    watching: isWatching
                )

                activeProcessor = processor

                let attempts = try await Self.drive(
                    processor: processor,
                    range: section.range,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in self?.progress = fraction }
                    }
                )

                activeProcessor = nil

                let outcome = merge(section, attempts)
                tally.sections += 1
                tally.found += outcome.added
                tally.removed += outcome.removed

                onSectionFinished(section)
            } catch {
                activeProcessor = nil

                // Anything that isn't one of ours is a file or decoder problem, whose own
                // message says nothing about what the user was doing.
                failureMessage = (error as? Failure)?.errorDescription
                    ?? "That part of the video couldn't be read. (\(error.localizedDescription))"
                break
            }

            completedSections += 1
            progress = 0
        }

        activeSection = nil
        activeProcessor = nil
        isRunning = false
        isWatching = false
        summary = tally
    }

    // MARK: The pass

    /// Analyse one window and return what it found, with frame indices shifted back onto
    /// the clip's own numbering.
    ///
    /// Building and driving are separate so the caller can hold the processor while it
    /// runs — which is what a view needs to draw a pass the user is watching.
    nonisolated static func analyse(
        asset: AVAsset,
        range: ClosedRange<Double>,
        rim: HoopGeometry,
        exclusions: [ExclusionZone] = [],
        watching: Bool = false,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [ShotAttempt] {

        let processor = try await makeProcessor(
            asset: asset,
            range: range,
            rim: rim,
            exclusions: exclusions,
            watching: watching
        )

        return try await drive(processor: processor, range: range, onProgress: onProgress)
    }

    /// A reader restricted to one window, with the rim pinned and the model ready.
    nonisolated static func makeProcessor(
        asset: AVAsset,
        range: ClosedRange<Double>,
        rim: HoopGeometry,
        exclusions: [ExclusionZone] = [],
        watching: Bool
    ) async throws -> VideoProcessor {

        let span = max(range.upperBound - range.lowerBound, 0.1)

        let processor = try await VideoProcessor.create(
            videoAsset: asset,
            timeRange: CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                duration: CMTime(seconds: span, preferredTimescale: 600)
            ),
            producesPreviewFrames: watching
        )

        guard await processor.tracker.awaitVisionModel() != nil else {
            throw Failure.modelUnavailable
        }

        processor.tracker.setUserRim(rim)

        // The reason a re-run can come back with a different answer: the same footage,
        // with the user's knowledge of what isn't a ball applied to it.
        processor.tracker.setExclusionZones(exclusions)

        // Per-frame overlay snapshots only have an audience when somebody is watching,
        // and each one costs a hop to the main actor.
        processor.tracker.setOverlayUpdates(watching)

        return processor
    }

    /// Run a prepared processor to the end of its window.
    nonisolated static func drive(
        processor: VideoProcessor,
        range: ClosedRange<Double>,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [ShotAttempt] {

        let span = max(range.upperBound - range.lowerBound, 0.1)

        // Take the events straight off the processing thread: routing the results through
        // the tracker's main-actor `GameState` would mean waiting on hops that may not
        // have landed when the pass ends.
        //
        // Alongside, not instead of — that `GameState` is what the live readout counts,
        // so displacing its handler left a watched pass showing 0/0 however many shots it
        // was finding.
        let found = AttemptCollector()

        processor.tracker.shotTracker.onEvent = Self.collecting(
            into: found,
            alongside: processor.tracker.shotTracker.onEvent
        )

        // Throttled: a report per frame would be thirty main-actor hops a second to move
        // a progress bar by a pixel.
        var lastReported: Double = -1
        processor.onFrameProcessed = { time in
            guard let time else { return }
            let fraction = min(max((time - range.lowerBound) / span, 0), 1)
            if fraction - lastReported >= 0.02 {
                lastReported = fraction
                onProgress(fraction)
            }
        }

        processor.playback = .resume

        // Runs the same loop the first pass ran, and stops when the range is exhausted —
        // `readNextFrame` pauses and calls `clear()`, which resolves anything still open.
        await processor.play()

        guard processor.videoReader.status != .failed else { throw Failure.readFailed }

        onProgress(1)

        // The pass counted its own frames from zero, so its indices have to be moved back
        // onto the clip's numbering before they can sit alongside the original run's.
        let offset = Int((range.lowerBound * Double(processor.nominalFrameRate)).rounded())

        return found.attempts.map { $0.offsettingFrames(by: offset) }
    }
}

extension SectionReanalyser {

    /// Gather resolved attempts without displacing whatever else is listening.
    nonisolated static func collecting(
        into found: AttemptCollector,
        alongside existing: ((ShotEvent) -> Void)?
    ) -> (ShotEvent) -> Void {
        { event in
            if case .attemptResolved(let attempt) = event {
                found.append(attempt)
            }
            existing?(event)
        }
    }
}

/// Gathers resolved attempts from the frame-processing thread.
///
/// A box rather than a captured local, so the ownership is obvious: the analysis loop
/// writes, and only reads once the loop has finished.
final class AttemptCollector {
    private(set) var attempts: [ShotAttempt] = []

    func append(_ attempt: ShotAttempt) {
        attempts.append(attempt)
    }
}

extension ShotAttempt {

    /// Shift every frame index by `offset`.
    ///
    /// A ranged pass numbers frames from the start of its own window, so its indices
    /// would collide with the original run's. Only the numbering needs moving: the times
    /// are read from the sample buffers and are already absolute, and the trajectory fit
    /// that cared about frame spacing has already run — spacing is preserved anyway.
    ///
    /// The offset is derived from the track's nominal frame rate, so on
    /// variable-frame-rate footage it is an estimate. Frame indices are shown to the user
    /// and used for ordering, never for seeking, which is why an estimate is good enough
    /// here and would not be anywhere times are involved.
    func offsettingFrames(by offset: Int) -> ShotAttempt {
        guard offset != 0 else { return self }

        var moved = self
        moved.startFrame += offset
        moved.endFrame = endFrame.map { $0 + offset }

        moved.trajectory = trajectory.map { observation in
            BallObservation(
                frameID: observation.frameID + offset,
                center: observation.center,
                radius: observation.radius,
                confidence: observation.confidence,
                timeSeconds: observation.timeSeconds
            )
        }

        moved.crossings = crossings.map { crossing in
            RimCrossing(
                frame: crossing.frame + Double(offset),
                x: crossing.x,
                normalisedOffset: crossing.normalisedOffset,
                isClean: crossing.isClean,
                timeSeconds: crossing.timeSeconds
            )
        }

        return moved
    }
}
