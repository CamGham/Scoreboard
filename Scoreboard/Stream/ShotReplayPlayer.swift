//
//  ShotReplayPlayer.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation
import AVFoundation
import Observation

/// Plays back the window of a clip containing one shot, looping.
///
/// `AVAssetReader` can't seek backwards, so review playback goes through `AVPlayer`,
/// which can — and brings scrubbing and rate control with it. The reader keeps its job
/// of analysing the clip once, forwards; this is a separate pipeline for looking again.
@MainActor
@Observable
final class ShotReplayPlayer {

    let player: AVPlayer

    /// Padded bounds of the shot within the clip, in seconds.
    let window: ClosedRange<Double>

    private(set) var currentTime: Double
    private(set) var isPlaying = false

    /// Playback speed. Slow motion is the point of a replay — a shot resolves in under a
    /// second at full rate.
    var rate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = rate }
        }
    }

    /// True while the user is dragging the scrubber.
    ///
    /// The position is driven by the finger then, not the player, so player ticks must
    /// not write over it — and the window must not loop, or a drag to the end would
    /// snap the picture back to the start while the finger is still down.
    private(set) var isScrubbing = false

    private var wasPlayingBeforeScrub = false
    private var timeObserver: Any?
    private var didFinishLoading = false

    /// Seconds of run-up and run-out around the shot, so it has context either side.
    private static let padding: Double = 0.75

    init(asset: AVAsset, attempt: ShotAttempt) {
        let key = attempt.keyTime ?? 0
        let start = max(0, (attempt.startTime ?? key) - Self.padding)
        let end = max(start + 0.1, (attempt.endTime ?? key) + Self.padding)

        window = start...end
        currentTime = start

        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
    }

    // MARK: Lifecycle

    func start() {
        guard timeObserver == nil else { return }

        // Fine-grained, because the overlay's ball marker is positioned from this and a
        // coarse interval would make it visibly lag the picture.
        let interval = CMTime(value: 1, timescale: 60)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(time.seconds)
            }
        }

        Task {
            await seek(to: window.lowerBound)
            didFinishLoading = true
            play()
        }
    }

    /// Must be called before this object goes away.
    ///
    /// `AVPlayer` traps if it is deallocated while a time observer is still registered,
    /// so the observer cannot be left to `deinit` — main-actor isolation means it can't
    /// reliably be removed there.
    func stop() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        isPlaying = false
    }

    // MARK: Transport

    func play() {
        // Restart from the top if the last pass ran to the end.
        if currentTime >= window.upperBound - 0.01 {
            Task { await seek(to: window.lowerBound) }
        }
        isPlaying = true
        player.rate = rate
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Seek within the window.
    ///
    /// - Parameter precise: zero tolerance, so the overlay lines up with the exact frame
    ///   shown. Precise seeks decode from the preceding keyframe, which is too slow to do
    ///   continuously, so a live scrub passes false and only the final position is exact.
    func seek(to seconds: Double, precise: Bool = true) async {
        let clamped = min(max(seconds, window.lowerBound), window.upperBound)
        currentTime = clamped

        let tolerance: CMTime = precise
            ? .zero
            : CMTime(seconds: 0.04, preferredTimescale: 600)

        await player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    // MARK: Scrubbing

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    /// Move to a fraction of the window. Clamped, so the far end of the slider lands on
    /// the last frame of the shot rather than running past it.
    func scrub(toProgress fraction: Double) {
        let clampedFraction = min(max(fraction, 0), 1)
        let span = window.upperBound - window.lowerBound
        let target = window.lowerBound + (clampedFraction * span)

        Task { await seek(to: target, precise: false) }
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false

        let target = currentTime
        Task {
            await seek(to: target, precise: true)
            if wasPlayingBeforeScrub { play() }
        }
    }

    /// Step one frame at a time, for picking apart a rim contact.
    func step(by seconds: Double) {
        pause()
        Task { await seek(to: currentTime + seconds) }
    }

    /// Progress through the window, 0–1. Clamped, because a Slider bound to a value
    /// outside its range misbehaves.
    var progress: Double {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return 0 }
        return min(max((currentTime - window.lowerBound) / span, 0), 1)
    }

    private func handleTick(_ seconds: Double) {
        guard seconds.isFinite, didFinishLoading else { return }

        // The finger owns the position during a scrub; player ticks would fight it.
        guard !isScrubbing else { return }

        currentTime = seconds

        // Loop only when playback genuinely ran to the end of the window. Looping on any
        // arrival at the upper bound would also fire on a deliberate seek there.
        if isPlaying, seconds >= window.upperBound {
            Task {
                await seek(to: window.lowerBound)
                if isPlaying { player.rate = rate }
            }
        }
    }
}
