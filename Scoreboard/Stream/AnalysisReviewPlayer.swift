//
//  AnalysisReviewPlayer.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation
import AVFoundation
import Observation

/// Plays the whole analysed clip, with the transport a review pass needs: free scrubbing,
/// rate control, and jumps straight to a given moment.
///
/// `ShotReplayPlayer` is the sibling of this — same underlying `AVPlayer`, but pinned to
/// one shot's window and looping. This one never loops and never clamps to a shot: the
/// point is to move across the entire video, using the detected shots as landmarks rather
/// than as boundaries.
@MainActor
@Observable
final class AnalysisReviewPlayer {

    let player: AVPlayer

    /// Length of the clip in seconds. Zero until the asset reports it, which is why the
    /// scrubber has to tolerate a zero duration for the first frame or two.
    private(set) var duration: Double = 0

    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    /// True while the user is dragging the scrubber. Player ticks are ignored then — the
    /// finger owns the position, and a tick landing mid-drag would fight it.
    private(set) var isScrubbing = false

    /// Playback speed. A shot resolves in well under a second, so slow motion is as much
    /// a part of review here as it is in the single-shot replay.
    var rate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = rate }
        }
    }

    private let asset: AVAsset
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var wasPlayingBeforeScrub = false

    init(asset: AVAsset) {
        self.asset = asset
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
    }

    // MARK: Lifecycle

    /// - Parameter initialTime: where to open. Applied once the duration is known, so a
    ///   jump to the first shot isn't clamped away by a duration that hasn't loaded yet.
    func start(seekingTo initialTime: Double? = nil) {
        guard timeObserver == nil else { return }

        // Fine-grained: the overlay's ball marker is positioned from this, and a coarse
        // interval would make it visibly lag the picture.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }

        Task {
            // Read the duration from the asset, not the item: an item's duration is
            // indefinite until it becomes ready, and the scrubber can't lay markers out
            // against that.
            let loaded = (try? await asset.load(.duration))?.seconds ?? 0
            if loaded.isFinite, loaded > 0 { duration = loaded }

            if let initialTime { await seek(to: initialTime) }
        }
    }

    /// Must be called before this object goes away — `AVPlayer` traps if it is
    /// deallocated with a time observer still registered.
    func stop() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        isPlaying = false
    }

    // MARK: Transport

    func play() {
        // Nothing to play from the very end — start over rather than sit there.
        if duration > 0, currentTime >= duration - 0.05 {
            Task { await seek(to: 0) }
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

    /// Seek anywhere in the clip.
    ///
    /// - Parameter precise: zero tolerance, so the trajectory overlay lines up with the
    ///   exact frame on screen. Precise seeks decode from the preceding keyframe, which is
    ///   too slow to run continuously, so a live scrub passes false and only the final
    ///   position is exact.
    func seek(to seconds: Double, precise: Bool = true) async {
        // Only clamp against a duration that has actually loaded — clamping to a zero
        // duration would pin every early seek to the start of the clip.
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        currentTime = clamped

        let tolerance: CMTime = precise
            ? .zero
            : CMTime(seconds: 0.05, preferredTimescale: 600)

        await player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    /// Jump to a moment and keep playing if it already was — what tapping a shot marker
    /// or the next-shot button should feel like.
    func jump(to seconds: Double) {
        let resume = isPlaying
        pause()
        Task {
            await seek(to: seconds)
            if resume { play() }
        }
    }

    /// Step one frame at a time, for picking apart a rim contact.
    func step(by seconds: Double) {
        pause()
        Task { await seek(to: currentTime + seconds) }
    }

    // MARK: Scrubbing

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    /// Move to an absolute time while the finger is down. Coarse on purpose — the frame
    /// under the finger only has to be close, and the precise seek lands on release.
    func scrub(to seconds: Double) {
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        currentTime = clamped
        Task { await seek(to: clamped, precise: false) }
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

    /// Progress through the clip, 0–1.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func handleTick(_ seconds: Double) {
        guard seconds.isFinite, !isScrubbing else { return }
        currentTime = seconds
    }
}
