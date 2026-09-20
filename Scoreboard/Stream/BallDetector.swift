//
//  BallDetector.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation
import Vision
import CoreVideo

/// Running tally of how the ball is being found, so the crop can be judged against the
/// full-frame sweep it replaced rather than taken on faith.
struct BallDetectionStats: Codable, Equatable {
    var framesProcessed = 0

    var croppedAttempts = 0
    var croppedHits = 0

    var fullFrameAttempts = 0
    var fullFrameHits = 0

    private var confidenceSum: Double = 0

    var totalHits: Int { croppedHits + fullFrameHits }

    var croppedHitRate: Double {
        croppedAttempts > 0 ? Double(croppedHits) / Double(croppedAttempts) : 0
    }

    var fullFrameHitRate: Double {
        fullFrameAttempts > 0 ? Double(fullFrameHits) / Double(fullFrameAttempts) : 0
    }

    var meanConfidence: Double {
        totalHits > 0 ? confidenceSum / Double(totalHits) : 0
    }

    /// Share of processed frames that produced a ball. This is the number that matters
    /// for shot detection — a trajectory fit needs consecutive sightings.
    var overallHitRate: Double {
        framesProcessed > 0 ? Double(totalHits) / Double(framesProcessed) : 0
    }

    mutating func record(hit: Bool, cropped: Bool, confidence: Double) {
        framesProcessed += 1

        if cropped {
            croppedAttempts += 1
            if hit { croppedHits += 1 }
        } else {
            fullFrameAttempts += 1
            if hit { fullFrameHits += 1 }
        }

        if hit { confidenceSum += confidence }
    }
}

/// Finds the ball by detecting inside a moving crop rather than tracking it visually.
///
/// The ball used to ride the same `VNTrackObjectRequest` path as the players. That is a
/// poor fit: correlation tracking has no motion model, and a small motion-blurred ball
/// is its worst case — the pipeline carried explicit workarounds for tracks latching
/// onto background. A ballistic fit is a far better predictor, so the ball is now
/// predicted and re-detected every frame instead of tracked, which also hands a tracking
/// slot back to the players.
final class BallDetector {

    enum Mode: Equatable {
        /// No usable prediction — sweep the whole frame.
        case searching
        /// Detect inside a crop around the predicted position.
        case cropped(CGRect)
    }

    private let model: VNCoreMLModel
    private let config: BallROIPredictor.Config

    /// Confidence floor when sweeping the full frame.
    private let fullFrameConfidence: Float = 0.45

    /// Confidence floor inside the crop.
    ///
    /// Lower on purpose. Location is already strongly constrained by the prediction, so
    /// a middling box in the right place is far more likely to be the ball than the same
    /// score anywhere in a full frame.
    private let croppedConfidence: Float = 0.25

    private(set) var consecutiveMisses = 0
    private(set) var stats = BallDetectionStats()
    private(set) var lastMode: Mode = .searching

    init(model: VNCoreMLModel, config: BallROIPredictor.Config = BallROIPredictor.Config()) {
        self.model = model
        self.config = config
    }

    func reset() {
        consecutiveMisses = 0
        stats = BallDetectionStats()
        lastMode = .searching
    }

    /// Detect the ball for one frame.
    ///
    /// - Returns: the ball's bounding box in *full-frame* Vision normalized space, with
    ///   its confidence, or nil when nothing was found.
    func detect(
        pixelBuffer: CVImageBuffer,
        orientation: CGImagePropertyOrientation,
        frameID: Int,
        history: [BallObservation],
        fit: MotionFit?
    ) -> (boundingBox: CGRect, confidence: Float)? {

        let aspect = orientedAspect(of: pixelBuffer, orientation: orientation)
        let mode = chooseMode(history: history, fit: fit, frameID: frameID, aspect: aspect)
        lastMode = mode

        let predictedCentre = BallROIPredictor.predictedCentre(
            history: history, fit: fit, atFrame: frameID, config: config
        )

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        var roi: CGRect?
        switch mode {
        case .searching:
            break
        case .cropped(let rect):
            request.regionOfInterest = rect
            roi = rect
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])

        let threshold = roi == nil ? fullFrameConfidence : croppedConfidence

        let candidates = (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { $0.labels.first?.identifier == ObjectType.ball.rawValue }
            .filter { $0.confidence >= threshold }

        guard let chosen = pick(from: candidates, roi: roi, predictedCentre: predictedCentre) else {
            consecutiveMisses += 1
            stats.record(hit: false, cropped: roi != nil, confidence: 0)
            return nil
        }

        let box = roi.map {
            BallROIPredictor.mapToFullFrame(roiRelative: chosen.boundingBox, roi: $0)
        } ?? chosen.boundingBox

        consecutiveMisses = 0
        stats.record(hit: true, cropped: roi != nil, confidence: Double(chosen.confidence))

        return (box, chosen.confidence)
    }

    // MARK: Choosing

    private func chooseMode(
        history: [BallObservation],
        fit: MotionFit?,
        frameID: Int,
        aspect: Double
    ) -> Mode {

        // Too many misses in a row means the prediction has gone stale; sweep instead of
        // searching an ever-larger crop around a position the ball long since left.
        guard consecutiveMisses < config.missesBeforeFullFrame else { return .searching }

        guard let centre = BallROIPredictor.predictedCentre(
            history: history, fit: fit, atFrame: frameID, config: config
        ) else {
            return .searching
        }

        let side = BallROIPredictor.sideFraction(consecutiveMisses: consecutiveMisses, config: config)

        return .cropped(
            BallROIPredictor.regionOfInterest(around: centre, sideFraction: side, aspect: aspect)
        )
    }

    /// Inside a crop the prediction is a strong prior, so the nearest candidate beats the
    /// most confident one — a stray high-scoring box at the edge of the window is more
    /// likely a head or a shoe than the ball.
    private func pick(
        from candidates: [VNRecognizedObjectObservation],
        roi: CGRect?,
        predictedCentre: CGPoint?
    ) -> VNRecognizedObjectObservation? {

        guard !candidates.isEmpty else { return nil }

        guard let roi, let predictedCentre else {
            return candidates.max(by: { $0.confidence < $1.confidence })
        }

        return candidates.min(by: { lhs, rhs in
            distance(of: lhs, roi: roi, to: predictedCentre)
                < distance(of: rhs, roi: roi, to: predictedCentre)
        })
    }

    private func distance(
        of observation: VNRecognizedObjectObservation,
        roi: CGRect,
        to point: CGPoint
    ) -> CGFloat {
        let box = BallROIPredictor.mapToFullFrame(roiRelative: observation.boundingBox, roi: roi)
        return hypot(box.midX - point.x, box.midY - point.y)
    }

    // MARK: Frame geometry

    /// Aspect ratio of the image *as Vision sees it*.
    ///
    /// Vision's normalized space is relative to the oriented image, so a quarter-turn
    /// swaps width and height. Getting this backwards would make every crop a tall
    /// rectangle instead of a square and quietly give back the letterboxing.
    private func orientedAspect(
        of pixelBuffer: CVImageBuffer,
        orientation: CGImagePropertyOrientation
    ) -> Double {
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return 1 }

        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return height / width
        default:
            return width / height
        }
    }
}
