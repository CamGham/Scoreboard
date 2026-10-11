//
//  AppearanceSeparation.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import Foundation

/// How well each appearance cue tells the players in this clip apart.
///
/// Measured without trusting anyone's identity labels — they are what this is meant to
/// fix, so a profile built from them would mix two people. Two things are known without
/// labels:
///
/// - A **tracklet** — a track's stretch between overlaps — is one person. Its running
///   average is what they look like.
/// - Two tracklets seen cleanly on the **same frame** are two different people.
///
/// So each clean sample is checked against its own tracklet's average and against every
/// other tracklet on the same frame. A cue that keeps putting the sample nearer its own
/// tells the players apart; one that is right half the time is a coin flip.
struct AppearanceSeparation {

    enum Cue: String, CaseIterable, Codable {
        case head, torso, shorts, legs, feet, height, build

        /// The colour band this cue reads, if it is one.
        var band: AppearanceSampler.Band? {
            switch self {
            case .head: .head
            case .torso: .torso
            case .shorts: .shorts
            case .legs: .legs
            case .feet: .feet
            case .height, .build: nil
            }
        }
    }

    struct Config: Equatable {
        /// Confidence a detection needs for its player to be sampled.
        var minimumConfidence: Float = 0.6

        /// How far either side of a box another player's box must stay, as a fraction of
        /// its width, for the box to count as clear of them.
        var clearance: CGFloat = 0.1

        /// Samples a tracklet needs before its average is worth comparing against.
        var samplesBeforeComparing = 3

        /// Samples, and spread of foot positions, before box height is judged against the
        /// clip's perspective — a line through a few samples at one spot means nothing.
        var heightModelSamples = 50
        var heightModelSpread: CGFloat = 0.1
    }

    /// How often one cue put a sample nearer its own tracklet.
    struct Score: Codable, Equatable {
        /// Ties count half.
        var correct: Double = 0
        var compared = 0

        var accuracy: Double { compared > 0 ? correct / Double(compared) : 0 }

        mutating func add(own: Double, other: Double) {
            compared += 1
            correct += own < other ? 1 : own == other ? 0.5 : 0
        }
    }

    struct Summary: Codable, Equatable {
        /// Single-sample comparisons made: one clean sample, its own tracklet, and another
        /// seen on the same frame.
        var comparisons = 0

        /// By `Cue` raw value.
        var cues: [String: Score] = [:]

        /// Every cue at once, each scaled by how much it usually varies for one person.
        var combined = Score()

        func score(for cue: Cue) -> Score { cues[cue.rawValue] ?? Score() }
    }

    let config: Config

    private(set) var summary = Summary()

    /// Each visible track's current tracklet, by track id.
    private var tracklets: [Int: Tracklet] = [:]

    /// Box height against foot position across every clean sample: how tall someone
    /// looks at each distance from the camera.
    private var heightFit = LineFit()

    /// How far a sample usually sits from its own tracklet, per cue — the scale for the
    /// combined score, so a cue measured in big numbers can't drown out the rest.
    private var spread: [Cue: (total: Double, count: Int)] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    /// The tracks worth sampling on `frameID`: matched on it, confident, and clear of
    /// every other player. A coasting box is a guess, and one touching someone else
    /// would read part of them.
    static func cleanTracks(
        _ tracks: [PlayerTrack],
        at frameID: Int,
        config: Config = Config()
    ) -> [PlayerTrack] {
        tracks.filter { track in
            track.lastSeenFrame == frameID
                && track.confidence >= config.minimumConfidence
                && !isTouching(track, among: tracks, clearance: config.clearance)
        }
    }

    /// Move on to `frameID`.
    ///
    /// - Parameters:
    ///   - tracks: the visible tracks, to notice overlaps and ended tracks.
    ///   - samples: this frame's clean samples, by track id. Empty on frames without
    ///     detections.
    mutating func update(frameID: Int, tracks: [PlayerTrack], samples: [Int: AppearanceSample]) {
        // An overlap ends a tracklet: whoever comes out of it may not be who went in.
        let live = Set(tracks.map(\.id))
        tracklets = tracklets.filter { live.contains($0.key) }
        for track in tracks where Self.isTouching(track, among: tracks, clearance: config.clearance) {
            tracklets[track.id] = nil
        }

        let ratios = samples.mapValues { heightRatio(of: $0) }
        let ready = samples.filter { (tracklets[$0.key]?.count ?? 0) >= config.samplesBeforeComparing }

        for (id, sample) in ready {
            guard let own = tracklets[id] else { continue }
            for (otherID, _) in ready where otherID != id {
                guard let other = tracklets[otherID] else { continue }
                compare(sample, ratio: ratios[id] ?? nil, own: own, other: other)
            }
        }

        for (id, sample) in samples {
            tracklets[id, default: Tracklet()].add(sample, heightRatio: ratios[id] ?? nil)
            heightFit.add(x: sample.footY, y: sample.height)
        }
    }

    // MARK: Comparing

    private mutating func compare(_ sample: AppearanceSample, ratio: CGFloat?, own: Tracklet, other: Tracklet) {
        summary.comparisons += 1

        var combinedOwn = 0.0
        var combinedOther = 0.0

        for cue in Cue.allCases {
            guard let distance = distances(for: cue, sample: sample, ratio: ratio, own: own, other: other) else {
                continue
            }
            let (toOwn, toOther) = distance

            summary.cues[cue.rawValue, default: Score()].add(own: toOwn, other: toOther)

            // Floored so a cue that never varies — a perfectly still test, a solid colour
            // — can't divide by zero and dominate.
            let usual = spread[cue].map { $0.total / Double($0.count) } ?? 0
            let scale = max(usual, 1e-3)
            combinedOwn += toOwn / scale
            combinedOther += toOther / scale

            spread[cue, default: (0, 0)].total += toOwn
            spread[cue, default: (0, 0)].count += 1
        }

        summary.combined.add(own: combinedOwn, other: combinedOther)
    }

    /// How far `sample` is from each tracklet on one cue, or nil when the cue can't be
    /// read for this comparison.
    private func distances(
        for cue: Cue,
        sample: AppearanceSample,
        ratio: CGFloat?,
        own: Tracklet,
        other: Tracklet
    ) -> (own: Double, other: Double)? {
        if let band = cue.band {
            let histogram = sample.bands[band.rawValue]
            guard histogram.contains(where: { $0 > 0 }) else { return nil }
            return (
                Self.hellinger(histogram, own.meanBand(band)),
                Self.hellinger(histogram, other.meanBand(band))
            )
        }

        switch cue {
        case .height:
            guard let ratio, let ownRatio = own.meanHeightRatio, let otherRatio = other.meanHeightRatio else {
                return nil
            }
            return (Double(abs(ratio - ownRatio)), Double(abs(ratio - otherRatio)))
        case .build:
            return (Double(abs(sample.aspect - own.meanAspect)), Double(abs(sample.aspect - other.meanAspect)))
        default:
            return nil
        }
    }

    /// Box height over the height expected at its foot position, once the clip's
    /// perspective has been learned.
    private func heightRatio(of sample: AppearanceSample) -> CGFloat? {
        guard heightFit.count >= config.heightModelSamples,
              heightFit.spread >= config.heightModelSpread,
              let expected = heightFit.value(at: sample.footY), expected > 0.01
        else { return nil }
        return sample.height / expected
    }

    /// Distance between two histograms that each sum to 1: 0 for identical, 1 for no
    /// overlap at all.
    static func hellinger(_ p: [Float], _ q: [Float]) -> Double {
        var overlap: Float = 0
        for index in p.indices {
            overlap += (p[index] * q[index]).squareRoot()
        }
        return Double(max(0, 1 - overlap).squareRoot())
    }

    private static func isTouching(_ track: PlayerTrack, among tracks: [PlayerTrack], clearance: CGFloat) -> Bool {
        let zone = track.box.insetBy(dx: -track.box.width * clearance, dy: 0)
        return tracks.contains { $0.id != track.id && $0.box.intersects(zone) }
    }

    // MARK: Accumulators

    /// Running averages of one tracklet's samples.
    private struct Tracklet {
        var count = 0
        var bandTotals = [[Float]](
            repeating: [Float](repeating: 0, count: AppearanceSampler.binCount),
            count: AppearanceSampler.Band.allCases.count
        )
        var bandCounts = [Int](repeating: 0, count: AppearanceSampler.Band.allCases.count)
        var heightRatioTotal: CGFloat = 0
        var heightRatioCount = 0
        var aspectTotal: CGFloat = 0

        var meanAspect: CGFloat { count > 0 ? aspectTotal / CGFloat(count) : 0 }

        var meanHeightRatio: CGFloat? {
            heightRatioCount > 0 ? heightRatioTotal / CGFloat(heightRatioCount) : nil
        }

        func meanBand(_ band: AppearanceSampler.Band) -> [Float] {
            let count = bandCounts[band.rawValue]
            guard count > 0 else { return bandTotals[band.rawValue] }
            return bandTotals[band.rawValue].map { $0 / Float(count) }
        }

        mutating func add(_ sample: AppearanceSample, heightRatio: CGFloat?) {
            count += 1
            aspectTotal += sample.aspect

            for index in sample.bands.indices where sample.bands[index].contains(where: { $0 > 0 }) {
                for bin in sample.bands[index].indices {
                    bandTotals[index][bin] += sample.bands[index][bin]
                }
                bandCounts[index] += 1
            }

            if let heightRatio {
                heightRatioTotal += heightRatio
                heightRatioCount += 1
            }
        }
    }

    /// Least-squares straight line through points added one at a time.
    private struct LineFit {
        private(set) var count = 0
        private var sumX: CGFloat = 0
        private var sumY: CGFloat = 0
        private var sumXX: CGFloat = 0
        private var sumXY: CGFloat = 0
        private var minX: CGFloat = .infinity
        private var maxX: CGFloat = -.infinity

        /// Range of x seen.
        var spread: CGFloat { count > 0 ? maxX - minX : 0 }

        mutating func add(x: CGFloat, y: CGFloat) {
            count += 1
            sumX += x
            sumY += y
            sumXX += x * x
            sumXY += x * y
            minX = min(minX, x)
            maxX = max(maxX, x)
        }

        func value(at x: CGFloat) -> CGFloat? {
            let n = CGFloat(count)
            let denominator = n * sumXX - sumX * sumX
            guard count >= 2, abs(denominator) > 1e-9 else { return nil }

            let slope = (n * sumXY - sumX * sumY) / denominator
            let intercept = (sumY - slope * sumX) / n
            return intercept + slope * x
        }
    }
}
