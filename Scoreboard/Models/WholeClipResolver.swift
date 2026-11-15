//
//  WholeClipResolver.swift
//  Scoreboard
//
//  Created by Cam Graham on 18/10/2026.
//

import Foundation

/// Second-guesses the live identities once a recorded clip has ended, using everything
/// the clip showed of each player.
///
/// The live checks are a chain: each touch links the look just before it to the look
/// just after, and nothing else. They are good — same spot, same light — but one wrong
/// link carries on until another happens to undo it. Here every tracklet is compared
/// with how each player looked across the rest of the clip instead, so one bad link is
/// outvoted.
///
/// - The live labels are the starting point; the pass only moves what the evidence
///   clearly says is wrong.
/// - Tracklets on screen at the same time are different people, so they move together:
///   tracklets whose frames overlap form an **interval**, and with two players the only
///   choice for an interval is to keep its labels or flip them.
/// - A tracklet is compared with a player's looks **taken nearest the same spot** across
///   the frame, since what is behind someone changes how they read.
/// - The interval that would gain most is flipped first, then everything is scored again
///   — a flip changes what each player looks like — until nothing clears the margin.
/// - The first interval is never flipped. It is where the players were first seen and
///   numbered, so it defines who P1 and P2 are; with little else in the clip to go on,
///   flipping it would rename everyone rather than correct anyone.
///
/// Two players only, for now: with more, an interval has many possible labellings rather
/// than two.
enum WholeClipResolver {

    struct Config: Codable, Equatable {
        /// Looks of a player each tracklet is compared with: the ones taken nearest to it
        /// across the frame.
        var nearestLooks = 3

        /// How much better flipped has to fit than as labelled to be moved — the same as
        /// the live checks.
        var clearMargin = 0.15

        /// Flips at most, so a pass can't go round in circles.
        var maxFlips = 200
    }

    struct Tracklet {
        let trackID: Int
        let firstFrame: Int
        let lastFrame: Int

        /// Index of the player it is labelled as.
        let player: Int

        let look: AppearanceSeparation.Look
    }

    /// One interval that ended up with its labels the other way round.
    struct Move: Equatable {
        /// Indices into the tracklets passed in.
        let tracklets: [Int]

        /// Cost flipped over cost as labelled, when it was flipped.
        let ratio: Double
    }

    struct Result {
        /// The player for each tracklet passed in, in the same order.
        let players: [Int]
        let moves: [Move]
    }

    static func resolve(
        _ tracklets: [Tracklet],
        config: Config = Config(),
        distance: (AppearanceSeparation.Look, AppearanceSeparation.Look) -> Double?
    ) -> Result {
        var players = tracklets.map(\.player)
        guard Set(players).isSubset(of: [0, 1]) else {
            return Result(players: players, moves: [])
        }

        let intervals = Self.intervals(tracklets).filter { isConsistent($0, tracklets: tracklets) }
        let anchor = tracklets.indices.min { tracklets[$0].firstFrame < tracklets[$1].firstFrame }
        let intervalOf = Dictionary(
            intervals.enumerated().flatMap { index, members in members.map { ($0, index) } },
            uniquingKeysWith: { first, _ in first }
        )

        var flips = [Int: (count: Int, ratio: Double)]()

        for _ in 0..<config.maxFlips {
            var best: (interval: Int, ratio: Double)?

            for (index, members) in intervals.enumerated() where anchor.map({ !members.contains($0) }) ?? true {
                var asLabelled = 0.0
                var flipped = 0.0
                var scorable = true

                for member in members {
                    guard let keep = cost(of: member, as: players[member], tracklets, players, intervalOf, config, distance),
                          let swap = cost(of: member, as: 1 - players[member], tracklets, players, intervalOf, config, distance)
                    else {
                        scorable = false
                        break
                    }
                    asLabelled += keep
                    flipped += swap
                }

                guard scorable, asLabelled > 0, flipped < asLabelled * (1 - config.clearMargin) else { continue }

                let ratio = flipped / asLabelled
                if best == nil || ratio < best!.ratio {
                    best = (index, ratio)
                }
            }

            guard let best else { break }

            for member in intervals[best.interval] {
                players[member] = 1 - players[member]
            }
            let previous = flips[best.interval]?.count ?? 0
            flips[best.interval] = (previous + 1, best.ratio)
        }

        // Only intervals flipped an odd number of times ended up moved.
        let moves = flips
            .filter { $0.value.count % 2 == 1 }
            .sorted { intervals[$0.key][0] < intervals[$1.key][0] }
            .map { Move(tracklets: intervals[$0.key].sorted(), ratio: $0.value.ratio) }

        return Result(players: players, moves: moves)
    }

    // MARK: Intervals

    /// Tracklets linked by overlapping frames, directly or through others.
    static func intervals(_ tracklets: [Tracklet]) -> [[Int]] {
        var parent = Array(tracklets.indices)

        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        let byStart = tracklets.indices.sorted { tracklets[$0].firstFrame < tracklets[$1].firstFrame }
        for (position, index) in byStart.enumerated() {
            for other in byStart[(position + 1)...] {
                guard tracklets[other].firstFrame <= tracklets[index].lastFrame else { break }
                parent[root(other)] = root(index)
            }
        }

        return Dictionary(grouping: tracklets.indices, by: root)
            .values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// Whether every pair of tracklets on screen together is labelled as different
    /// players. One that isn't can't be justified either way round, so it's left alone.
    private static func isConsistent(_ members: [Int], tracklets: [Tracklet]) -> Bool {
        for (position, a) in members.enumerated() {
            for b in members[(position + 1)...] {
                let overlap = tracklets[a].firstFrame <= tracklets[b].lastFrame
                    && tracklets[b].firstFrame <= tracklets[a].lastFrame
                if overlap && tracklets[a].player == tracklets[b].player {
                    return false
                }
            }
        }
        return true
    }

    // MARK: Scoring

    /// How far `tracklet` is from how `player` looked elsewhere: its average distance to
    /// that player's looks taken nearest it across the frame, leaving out its own
    /// interval. Nil when the player has no other looks to compare with.
    private static func cost(
        of tracklet: Int,
        as player: Int,
        _ tracklets: [Tracklet],
        _ players: [Int],
        _ intervalOf: [Int: Int],
        _ config: Config,
        _ distance: (AppearanceSeparation.Look, AppearanceSeparation.Look) -> Double?
    ) -> Double? {
        let own = intervalOf[tracklet]
        let x = tracklets[tracklet].look.meanCentreX

        let nearest = tracklets.indices
            .filter { players[$0] == player && intervalOf[$0] != own }
            .sorted { abs(tracklets[$0].look.meanCentreX - x) < abs(tracklets[$1].look.meanCentreX - x) }
            .prefix(config.nearestLooks)

        let distances = nearest.compactMap { distance(tracklets[tracklet].look, tracklets[$0].look) }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }
}

extension WholeClipResolver.Config {
    // Lenient, so settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        nearestLooks = try container.decode(.nearestLooks, or: defaults.nearestLooks)
        clearMargin = try container.decode(.clearMargin, or: defaults.clearMargin)
        maxFlips = try container.decode(.maxFlips, or: defaults.maxFlips)
    }
}
