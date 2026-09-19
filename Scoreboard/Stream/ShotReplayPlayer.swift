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

    /// Frame-accurate seek — zero tolerance, because the overlay is drawn against the
    /// exact moment and any slack puts the drawn ball off the pictured one.
    func seek(to seconds: Double) async {
        let clamped = min(max(seconds, window.lowerBound), window.upperBound)
        currentTime = clamped

        await player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Step one frame at a time, for picking apart a rim contact.
    func step(by seconds: Double) {
        pause()
        Task { await seek(to: currentTime + seconds) }
    }

    /// Progress through the window, 0–1.
    var progress: Double {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return 0 }
        return (currentTime - window.lowerBound) / span
    }

    private func handleTick(_ seconds: Double) {
        guard seconds.isFinite, didFinishLoading else { return }
        currentTime = seconds

        // Loop the window rather than running on into the rest of the clip.
        if seconds >= window.upperBound {
            Task {
                await seek(to: window.lowerBound)
                if isPlaying { player.rate = rate }
            }
        }
    }
}
