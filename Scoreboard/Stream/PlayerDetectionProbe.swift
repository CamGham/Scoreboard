//
//  PlayerDetectionProbe.swift
//  Scoreboard
//
//  Created by Cam Graham on 02/10/2026.
//

import Foundation
import Vision
import CoreVideo

/// One player box the model returned, in full-frame Vision normalized space.
struct PlayerDetection: Equatable {
    let boundingBox: CGRect
    let confidence: Float

    /// The players in a set of model results, down to the lowest confidence worth
    /// counting.
    static func players(in results: [VNRecognizedObjectObservation]) -> [PlayerDetection] {
        results
            .filter { $0.labels.first?.identifier == ObjectType.player.rawValue }
            .filter { $0.confidence >= PlayerDetectionStats.floorConfidence }
            .map { PlayerDetection(boundingBox: $0.boundingBox, confidence: $0.confidence) }
    }
}

/// The accepted player boxes from one sampled frame, kept so the next sample can be
/// checked against it.
struct PlayerSample: Equatable {
    let frameID: Int
    let boxes: [CGRect]
}

/// How well per-frame detection finds players, measured before anything is built on it.
///
/// Players are tracked with `VNTrackObjectRequest` today. Replacing that with detection
/// on every frame — as was done for the ball — only pays off if the detector finds the
/// same players frame after frame. These numbers answer that without ground truth:
///
/// - **Count** — how many players a frame yields, and how often it yields none.
/// - **Persistence** — the share of players that were also there in the previous
///   sample. Low persistence means boxes flicker, which an association layer would have
///   to coast through.
/// - **Confidence** — whether the 0.6 floor the tracker seeds from throws away players
///   that a lower floor would keep.
/// - **Tracker comparison** — how many tracks the current path held on the same
///   frames, so the two can be judged side by side.
struct PlayerDetectionStats: Codable, Equatable {

    /// The floor the tracker seeds new tracks from. Count and persistence are judged at
    /// this level so they compare like with like.
    static let acceptedConfidence: Float = 0.6

    /// Below this a box isn't counted at all — it only feeds the confidence buckets.
    static let floorConfidence: Float = 0.25

    /// Upper edges of the confidence buckets below `acceptedConfidence`.
    static let bucketEdges: [Float] = [0.4, acceptedConfidence]

    /// Overlap with a box in the previous sample needed to count a player as persisting.
    /// Generous on purpose — a player moves a little between samples, and a strict
    /// threshold would read ordinary motion as flicker.
    static let persistenceOverlap: CGFloat = 0.3

    /// Samples further apart than this aren't compared. Over a longer gap players really
    /// do move, and a missing match would be motion, not a missed detection.
    static let maxPairGap = 3

    /// Frames counted per number of players found, with the last bin holding that many
    /// or more.
    static let countBins = 11

    enum Source {
        /// Came free with the ball detector's full-frame sweep.
        case sweep
        /// An extra full-frame pass run only to take this measurement.
        case probe
    }

    /// How often a probe pass ran, if at all. Recorded because it changes how
    /// representative the sample is: sweeps only happen while the ball is lost.
    var probeInterval: Int?

    var sampledFrames = 0
    var sweepSamples = 0
    var probeSamples = 0

    /// Accepted players summed over every sampled frame.
    var acceptedDetections = 0

    /// Frames by how many accepted players they produced.
    var countHistogram = [Int](repeating: 0, count: PlayerDetectionStats.countBins)

    /// Every counted box by confidence: [floor, 0.4), [0.4, accepted), [accepted, 1].
    var confidenceBuckets = [0, 0, 0]

    /// Sampled frames with a previous sample close enough to compare against.
    var pairedFrames = 0
    /// Accepted players on those frames.
    var pairedDetections = 0
    /// Of those, the ones that overlapped a player in the previous sample.
    var persistedDetections = 0
    /// Change in player count between paired samples, summed.
    var countChangeSum = 0

    /// Player tracks the current path held on the sampled frames, summed.
    var trackedPlayerSum = 0

    init(probeInterval: Int? = nil) {
        self.probeInterval = probeInterval
    }

    // MARK: Derived

    var meanPlayersDetected: Double {
        sampledFrames > 0 ? Double(acceptedDetections) / Double(sampledFrames) : 0
    }

    var meanPlayersTracked: Double {
        sampledFrames > 0 ? Double(trackedPlayerSum) / Double(sampledFrames) : 0
    }

    var emptyFrameRate: Double {
        sampledFrames > 0 ? Double(countHistogram[0]) / Double(sampledFrames) : 0
    }

    var persistenceRate: Double {
        pairedDetections > 0 ? Double(persistedDetections) / Double(pairedDetections) : 0
    }

    var meanCountChange: Double {
        pairedFrames > 0 ? Double(countChangeSum) / Double(pairedFrames) : 0
    }

    /// Share of counted boxes that a lower floor would add.
    var belowAcceptedShare: Double {
        let total = confidenceBuckets.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(confidenceBuckets[0] + confidenceBuckets[1]) / Double(total)
    }

    // MARK: Recording

    /// Record one sampled frame.
    ///
    /// - Returns: this frame's accepted players, to pass back in as `previous` with the
    ///   next sample.
    @discardableResult
    mutating func record(
        frameID: Int,
        detections: [PlayerDetection],
        previous: PlayerSample?,
        trackedPlayers: Int,
        source: Source
    ) -> PlayerSample {

        sampledFrames += 1
        switch source {
        case .sweep: sweepSamples += 1
        case .probe: probeSamples += 1
        }

        for detection in detections where detection.confidence >= Self.floorConfidence {
            let bucket = Self.bucketEdges.firstIndex { detection.confidence < $0 }
                ?? Self.bucketEdges.count
            confidenceBuckets[bucket] += 1
        }

        let accepted = detections
            .filter { $0.confidence >= Self.acceptedConfidence }
            .map(\.boundingBox)

        acceptedDetections += accepted.count
        countHistogram[min(accepted.count, Self.countBins - 1)] += 1
        trackedPlayerSum += trackedPlayers

        if let previous, frameID > previous.frameID, frameID - previous.frameID <= Self.maxPairGap {
            pairedFrames += 1
            pairedDetections += accepted.count
            countChangeSum += abs(accepted.count - previous.boxes.count)

            persistedDetections += accepted.filter { box in
                previous.boxes.contains {
                    $0.intersectionOverUnion(with: box) >= Self.persistenceOverlap
                }
            }.count
        }

        return PlayerSample(frameID: frameID, boxes: accepted)
    }
}

/// Collects `PlayerDetectionStats` alongside a normal analysis pass.
///
/// Measurement only — nothing downstream reads what it finds. The ball detector's
/// full-frame sweeps are used whenever they happen, since they cost nothing extra. They
/// are a biased sample, though: a sweep means the ball was lost, which skews towards
/// dead-ball moments. So every `probeInterval` frames, if no sweep ran, the probe runs
/// its own full-frame pass to sample live play too.
final class PlayerDetectionProbe {

    /// Used for whole-clip analyses. A pass on every third frame keeps the extra cost
    /// down while leaving samples close enough together to pair.
    static let defaultInterval = 3

    private let model: VNCoreMLModel

    private(set) var stats: PlayerDetectionStats
    private var previous: PlayerSample?

    /// Every how many frames to run a pass of its own when the ball pass didn't sweep.
    var probeInterval: Int? {
        get { stats.probeInterval }
        set { stats.probeInterval = newValue }
    }

    /// - Parameter probeInterval: nil records sweeps only and never adds a pass.
    init(model: VNCoreMLModel, probeInterval: Int?) {
        self.model = model
        self.stats = PlayerDetectionStats(probeInterval: probeInterval)
    }

    /// Look at one frame.
    ///
    /// - Parameters:
    ///   - sweepPlayers: players from this frame's ball sweep, or nil if the ball pass
    ///     was cropped.
    ///   - trackedPlayers: player tracks the current path is holding.
    func observe(
        frameID: Int,
        sweepPlayers: [PlayerDetection]?,
        trackedPlayers: Int,
        pixelBuffer: CVImageBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        let detections: [PlayerDetection]
        let source: PlayerDetectionStats.Source

        if let sweepPlayers {
            detections = sweepPlayers
            source = .sweep
        } else if let interval = stats.probeInterval, interval > 0, frameID % interval == 0 {
            // Only around the probe's own pass — a sweep sample costs nothing to time.
            detections = PipelineSignpost.measure("Player probe") {
                detect(pixelBuffer: pixelBuffer, orientation: orientation)
            }
            source = .probe
        } else {
            return
        }

        previous = stats.record(
            frameID: frameID,
            detections: detections,
            previous: previous,
            trackedPlayers: trackedPlayers,
            source: source
        )
    }

    private func detect(
        pixelBuffer: CVImageBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [PlayerDetection] {
        // Same crop option as every other pass, so the probe sees what a per-frame
        // player detector would.
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])

        return PlayerDetection.players(in: request.results as? [VNRecognizedObjectObservation] ?? [])
    }
}
