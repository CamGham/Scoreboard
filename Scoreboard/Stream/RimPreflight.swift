//
//  RimPreflight.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation
import AVFoundation
import Vision
import CoreImage

/// Finds the rim in a prerecorded clip *before* playback starts.
///
/// The shot detector opens no attempts while the rim is unknown, so any shot that
/// happens before the rim is found is lost outright. Resolving it up front means the
/// whole clip is processed against a known scoring plane.
///
/// Frames are sampled across the clip's full duration rather than taken consecutively
/// from the start: a rim screened by players in the opening seconds usually isn't
/// thirty seconds later, and every sample lands in the same median regardless of when
/// it was taken — the rim doesn't move.
enum RimPreflight {

    struct Result {
        let geometry: HoopGeometry?
        /// How many sampled frames produced an accepted rim detection.
        let hits: Int
        let framesSampled: Int

        var didFind: Bool { geometry != nil }
    }

    /// Minimum confidence for a rim box to be counted.
    ///
    /// Deliberately below the pipeline's general 0.6 bar. A static object sampled many
    /// times is well served by a run of middling detections, because the median throws
    /// out the bad ones — and a missing rim costs far more than a slightly noisy one.
    static let minimumConfidence: Float = 0.4

    static func scan(
        asset: AVAsset,
        model: VNCoreMLModel,
        sampleCount: Int = 12
    ) async -> Result {

        let generator = AVAssetImageGenerator(asset: asset)
        // Hands back upright CGImages, so Vision needs no orientation fix-up here.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return Result(geometry: nil, hits: 0, framesSampled: 0)
        }

        let times = sampleTimes(duration: duration.seconds, count: sampleCount)

        var tracker = RimTracker()
        var hits = 0
        var sampled = 0

        for (index, seconds) in times.enumerated() {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)

            guard let cgImage = try? await generator.image(at: time).image else { continue }
            sampled += 1

            guard let box = detectRim(in: cgImage, model: model) else { continue }

            if tracker.observe(boundingBox: box, frameID: index) {
                hits += 1
            }
        }

        return Result(geometry: tracker.geometry, hits: hits, framesSampled: sampled)
    }

    /// Spread samples across the clip, skipping the very first and last moments where
    /// fades and camera settling are common.
    private static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard count > 1 else { return [duration / 2] }

        let start = min(0.5, duration * 0.02)
        let end = max(start, duration - min(0.5, duration * 0.02))

        return linspace(start, end, count)
    }

    /// Highest-confidence rim box in one frame, in Vision space.
    private static func detectRim(in image: CGImage, model: VNCoreMLModel) -> CGRect? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])

        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            return nil
        }

        let best = results
            .filter { $0.labels.first?.identifier == "Rim" && $0.confidence >= minimumConfidence }
            .max(by: { $0.confidence < $1.confidence })

        return best?.boundingBox
    }
}
