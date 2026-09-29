//
//  ShotFrameProvider.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation
import AVFoundation
import SwiftUI

/// Pulls the one still frame that best represents a shot, so the timeline can show what
/// happened instead of describing it.
///
/// `AVAssetReader` is strictly forward-only — there is no seeking back through it — so
/// random access to an arbitrary moment goes through `AVAssetImageGenerator` instead.
/// This only works because each attempt now carries a real presentation time; a frame
/// index can't be converted to one on variable-frame-rate footage.
@MainActor
final class ShotFrameProvider {

    private let generator: AVAssetImageGenerator

    private var cache: [UUID: Image] = [:]
    private var inFlight: [UUID: Task<Image?, Never>] = [:]

    init(asset: AVAsset, maximumSize: CGSize = CGSize(width: 720, height: 720)) {
        generator = AVAssetImageGenerator(asset: asset)

        // Upright frames, matching the orientation the tracker analysed.
        generator.appliesPreferredTrackTransform = true

        // Frame-accurate, deliberately. The overlay draws the ball where the detector saw
        // it at this exact instant; a frame of slack would put the drawn ball somewhere
        // the pictured ball isn't, which looks like a tracking bug rather than a seek one.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Keeps a list of these to a sane amount of memory.
        generator.maximumSize = maximumSize
    }

    /// The representative frame for an attempt — the rim crossing where there was one.
    ///
    /// Repeat calls for the same attempt share one decode: results are cached, and
    /// concurrent callers await the same task rather than each starting their own.
    func image(for attempt: ShotAttempt) async -> Image? {
        if let cached = cache[attempt.id] { return cached }
        if let running = inFlight[attempt.id] { return await running.value }

        guard let seconds = attempt.keyTime else { return nil }

        let task = Task { [generator] () -> Image? in
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else { return nil }
            return Image(decorative: cgImage, scale: 1)
        }

        inFlight[attempt.id] = task
        let image = await task.value
        inFlight[attempt.id] = nil

        if let image { cache[attempt.id] = image }
        return image
    }

    /// The frame at an arbitrary moment.
    ///
    /// Uncached: this is for one-off backdrops — placing a rim, blocking out an area —
    /// rather than for the timeline's repeated reads of the same few moments.
    func image(at seconds: Double) async -> Image? {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }
}
