//
//  PlayerDetection.swift
//  Scoreboard
//
//  Created by Cam Graham on 02/10/2026.
//

import Foundation
import Vision

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

/// How well detection finds players, and how well the tracker holds on to them.
///
/// First recorded to decide whether detection should replace `VNTrackObjectRequest` for
/// players; kept since as a health check on `PlayerTracker`. None of it needs ground
/// truth:
///
/// - **Count** — how many players a frame yields, and how often it yields none.
/// - **Persistence** — the share of players that were also there in the previous
///   sample. Low persistence means boxes flicker, which the tracker has to coast through.
/// - **Confidence** — how many boxes fall below the 0.6 floor a track starts from.
/// - **Tracker comparison** — how many players the tracker showed on the same frames.
/// - **Track lifetimes** (`tracking`) — whether identities hold or keep restarting.
///
/// Runs saved before the switch have no `tracking`; their tracked numbers are Apple's
/// tracker's.
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
        /// A scheduled player detection pass.
        case pass
    }

    /// Every how many frames a scheduled pass ran. Recorded because it changes how
    /// representative the sample is: sweeps only happen while the ball is lost.
    var passInterval: Int?

    var sampledFrames = 0
    var sweepSamples = 0
    var passSamples = 0

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

    /// Players the tracker showed on the sampled frames, summed.
    var trackedPlayerSum = 0

    /// How long the tracker's identities lasted. Nil for runs from before `PlayerTracker`.
    var tracking: TrackingSummary?

    struct TrackingSummary: Codable, Equatable {
        var config: PlayerTracker.Config

        /// Tracks that became confirmed. Ideally the number of people who were in shot;
        /// more means identities broke and restarted.
        var tracksConfirmed = 0

        /// Frames spanned by those tracks between them, from first sighting to last —
        /// those still running counted up to the moment the stats were taken.
        var confirmedTrackFrames = 0

        var meanTrackLifetimeFrames: Double {
            tracksConfirmed > 0 ? Double(confirmedTrackFrames) / Double(tracksConfirmed) : 0
        }
    }

    // The first runs called scheduled passes "probe" passes. Keep reading them.
    private enum CodingKeys: String, CodingKey {
        case passInterval = "probeInterval"
        case passSamples = "probeSamples"
        case sampledFrames, sweepSamples, acceptedDetections, countHistogram
        case confidenceBuckets, pairedFrames, pairedDetections, persistedDetections
        case countChangeSum, trackedPlayerSum, tracking
    }

    init(passInterval: Int? = nil) {
        self.passInterval = passInterval
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
        case .pass: passSamples += 1
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
