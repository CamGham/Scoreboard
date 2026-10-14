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
///
/// The tracklets, and how much each cue usually varies for one person, are also what
/// `IdentityTracker` compares looks with.
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

        /// Comparisons a cue needs before its accuracy decides its weight. About a second
        /// and a half of two players apart.
        var comparisonsBeforeWeighting = 30
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

        /// Clean samples behind the height model, and how much of the frame's height their
        /// feet covered. Nil for runs from before they were recorded.
        var heightSamples: Int?
        var footSpread: Double?

        func score(for cue: Cue) -> Score { cues[cue.rawValue] ?? Score() }
    }

    /// Running averages of one tracklet's samples: what one person looked like over it.
    struct Look {
        private(set) var count = 0
        private var bandTotals = [[Float]](
            repeating: [Float](repeating: 0, count: AppearanceSampler.binCount),
            count: AppearanceSampler.Band.allCases.count
        )
        private var bandCounts = [Int](repeating: 0, count: AppearanceSampler.Band.allCases.count)
        private var heightRatioTotal: CGFloat = 0
        private var heightRatioCount = 0
        private var aspectTotal: CGFloat = 0

        var meanAspect: CGFloat { count > 0 ? aspectTotal / CGFloat(count) : 0 }

        var meanHeightRatio: CGFloat? {
            heightRatioCount > 0 ? heightRatioTotal / CGFloat(heightRatioCount) : nil
        }

        func hasBand(_ band: AppearanceSampler.Band) -> Bool { bandCounts[band.rawValue] > 0 }

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

    let config: Config

    private var scores = Summary()

    /// Each visible track's current tracklet, by track id.
    private var tracklets: [Int: Look] = [:]

    /// Box height against foot position across every clean sample: how tall someone
    /// looks at each distance from the camera.
    private var heightFit = LineFit()

    /// How far a sample usually sits from its own tracklet, per cue — the scale for
    /// combining cues, so a cue measured in big numbers can't drown out the rest.
    private var spread: [Cue: (total: Double, count: Int)] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    var summary: Summary {
        var summary = scores
        summary.heightSamples = heightFit.count
        summary.footSpread = Double(heightFit.spread)
        return summary
    }

    /// `track`'s current tracklet: what it has looked like since it last touched anyone.
    func look(ofTrack id: Int) -> Look? { tracklets[id] }

    /// How different two looks are: a weighted average, over the cues both have, of each
    /// cue's difference scaled by how much it usually varies for one person. Nil if they
    /// share no cue that counts.
    ///
    /// Each cue is weighted by how well it has told the players in this clip apart — see
    /// `weight(for:config:)`. Without that, cues that barely separate anyone, and that
    /// shift for everybody with pose and lighting, add the same to every comparison and
    /// drown out the one that does.
    func distance(_ a: Look, _ b: Look) -> Double? {
        var total = 0.0
        var weights = 0.0

        for cue in Cue.allCases {
            guard let difference = Self.difference(for: cue, a, b) else { continue }
            let weight = Self.weight(for: scores.score(for: cue), config: config)
            total += weight * difference / scale(for: cue)
            weights += weight
        }

        return weights > 0 ? total / weights : nil
    }

    /// How much say a cue gets when looks are compared, from how often it picked the right
    /// player: its log-odds, ln(p ÷ (1 − p)). A cue right 99% of the time is far stronger
    /// evidence than one right 90%, not slightly stronger; a coin flip, or worse, is none.
    ///
    /// Every cue counts 1 until it has been compared enough to judge. Accuracy is capped
    /// so a cue that has never been wrong isn't infinitely sure.
    static func weight(for score: Score, config: Config = Config()) -> Double {
        guard score.compared >= config.comparisonsBeforeWeighting else { return 1 }
        let accuracy = min(score.accuracy, 0.995)
        guard accuracy > 0.5 else { return 0 }
        return log(accuracy / (1 - accuracy))
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

    /// Whether two players' boxes come within `clearance` of each other, as a fraction of
    /// either's width.
    static func touches(_ a: PlayerTrack, _ b: PlayerTrack, clearance: CGFloat) -> Bool {
        a.box.insetBy(dx: -a.box.width * clearance, dy: 0).intersects(b.box)
            || b.box.insetBy(dx: -b.box.width * clearance, dy: 0).intersects(a.box)
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
            tracklets[id, default: Look()].add(sample, heightRatio: ratios[id] ?? nil)
            heightFit.add(x: sample.footY, y: sample.height)
        }
    }

    // MARK: Comparing

    private mutating func compare(_ sample: AppearanceSample, ratio: CGFloat?, own: Look, other: Look) {
        scores.comparisons += 1

        var combinedOwn = 0.0
        var combinedOther = 0.0

        for cue in Cue.allCases {
            guard let distance = distances(for: cue, sample: sample, ratio: ratio, own: own, other: other) else {
                continue
            }
            let (toOwn, toOther) = distance

            scores.cues[cue.rawValue, default: Score()].add(own: toOwn, other: toOther)

            let scale = scale(for: cue)
            combinedOwn += toOwn / scale
            combinedOther += toOther / scale

            spread[cue, default: (0, 0)].total += toOwn
            spread[cue, default: (0, 0)].count += 1
        }

        scores.combined.add(own: combinedOwn, other: combinedOther)
    }

    /// How much `cue` usually varies for one person. Floored so a cue that never varies —
    /// a perfectly still test, a solid colour — can't divide by zero and dominate.
    private func scale(for cue: Cue) -> Double {
        let usual = spread[cue].map { $0.total / Double($0.count) } ?? 0
        return max(usual, 1e-3)
    }

    /// How far `sample` is from each tracklet on one cue, or nil when the cue can't be
    /// read for this comparison.
    private func distances(
        for cue: Cue,
        sample: AppearanceSample,
        ratio: CGFloat?,
        own: Look,
        other: Look
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

    /// How far apart two looks are on one cue, or nil when either lacks it.
    private static func difference(for cue: Cue, _ a: Look, _ b: Look) -> Double? {
        if let band = cue.band {
            guard a.hasBand(band), b.hasBand(band) else { return nil }
            return hellinger(a.meanBand(band), b.meanBand(band))
        }

        switch cue {
        case .height:
            guard let left = a.meanHeightRatio, let right = b.meanHeightRatio else { return nil }
            return Double(abs(left - right))
        case .build:
            guard a.count > 0, b.count > 0 else { return nil }
            return Double(abs(a.meanAspect - b.meanAspect))
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
        tracks.contains { $0.id != track.id && touches(track, $0, clearance: clearance) }
    }

    // MARK: Accumulators

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
