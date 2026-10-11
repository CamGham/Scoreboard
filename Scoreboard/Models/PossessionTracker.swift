//
//  PossessionTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import Foundation

/// Who held the ball on one frame.
struct PossessionFrame: Codable, Equatable {
    let frameID: Int
    let timeSeconds: Double?

    /// The holder's `PlayerTrack` id. Only meaningful within the run that produced it,
    /// and a track is not yet a person: when a track breaks, so does this.
    let playerID: Int

    /// The holder's box on this frame, in Vision normalized space.
    let box: CGRect

    /// False when the ball wasn't seen on this frame and the holder kept it by default.
    let ballSeen: Bool
}

/// One uninterrupted spell of a player holding the ball.
struct PossessionTouch: Equatable {
    let playerID: Int
    let startFrame: Int
    let endFrame: Int
    let startTime: Double?
    let endTime: Double?

    /// Where the holder was when the touch began and ended.
    let firstBox: CGRect
    let lastBox: CGRect
}

/// The run's possession: one entry for every frame on which someone held the ball.
///
/// Loose frames have no entry. Touches aren't stored separately — they are read off the
/// frames, so the two can never disagree.
struct PossessionRecord: Codable, Equatable {
    var config: PossessionTracker.Config
    var frames: [PossessionFrame] = []

    /// Who held the ball, in order. A touch is a run of frames with the same holder; the
    /// ball going loose and coming back to the same player doesn't start a new one.
    var touches: [PossessionTouch] {
        var result: [PossessionTouch] = []
        var start = 0

        for index in frames.indices {
            let isLastOfRun = index == frames.count - 1
                || frames[index + 1].playerID != frames[index].playerID
            guard isLastOfRun else { continue }

            let first = frames[start]
            let last = frames[index]
            result.append(PossessionTouch(
                playerID: first.playerID,
                startFrame: first.frameID,
                endFrame: last.frameID,
                startTime: first.timeSeconds,
                endTime: last.timeSeconds,
                firstBox: first.box,
                lastBox: last.box
            ))
            start = index + 1
        }

        return result
    }

    /// Index of the latest entry on or before `frameID` — the last time anyone held the
    /// ball up to then.
    func lastIndex(atOrBefore frameID: Int) -> Int? {
        var low = 0
        var high = frames.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].frameID <= frameID {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// The holder at a moment in the media, for drawing during playback.
    ///
    /// Playback times rarely land exactly on a stored frame, so this takes the latest
    /// entry at or before `time`. Loose frames have no entry, so when that entry is
    /// older than `maxAge` the ball was loose then and there is no holder.
    func frame(atTime time: Double, maxAge: Double = 0.1) -> PossessionFrame? {
        var low = 0
        var high = frames.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if (frames[mid].timeSeconds ?? -.infinity) <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let found, let stamped = frames[found].timeSeconds, time - stamped <= maxAge else {
            return nil
        }
        return frames[found]
    }

    /// The holder on `frameID`, or nil if nobody held the ball then.
    func frame(at frameID: Int) -> PossessionFrame? {
        var low = 0
        var high = frames.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].frameID == frameID { return frames[mid] }
            if frames[mid].frameID < frameID { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}

/// Decides, frame by frame, which player has the ball.
///
/// - A player holds the ball while it is within their **reach**: their box, padded
///   upward for an overhead release and down and sideways for a dribble.
/// - Outside everyone's reach, the ball is **loose**. Nobody holds it, but the last
///   holder is remembered — the passer or shooter it came from.
/// - When the ball can't be seen, the holder keeps it.
/// - The current holder is favoured. A different player only takes the ball after being
///   the best candidate on several sightings in a row, so a ball brushing past a
///   defender, or two players standing close, doesn't flick possession back and forth.
///   When a switch is confirmed, the frames of the streak are given to the new holder,
///   so the record shows when they actually got it.
/// - Possession ends when the holder's track is dropped, or the ball has been unseen
///   for too long.
struct PossessionTracker {

    struct Config: Codable, Equatable {
        /// Reach above the box, as a fraction of its height.
        var reachUp: CGFloat = 0.30
        /// Reach either side, as a fraction of its width.
        var reachSide: CGFloat = 0.25
        /// Reach below the box, as a fraction of its height.
        var reachDown: CGFloat = 0.10

        /// Consecutive sightings a new player must be the best candidate on before the
        /// ball is theirs. About a tenth of a second at 30 fps.
        var sightingsToSwitch = 3

        /// Frames the ball may go unseen before possession ends. Two seconds at 30 fps.
        var maxUnseenFrames = 60
    }

    let config: Config

    private(set) var record: PossessionRecord

    /// Who has the ball now. Nil while it is loose or nobody has it.
    private(set) var holderID: Int?

    /// Who had it last, kept while the ball is loose.
    private(set) var lastHolderID: Int?

    private var lastBallFrame: Int?

    /// A challenger being the best candidate on consecutive sightings.
    private struct Streak {
        let playerID: Int
        var sightings: Int
        /// This player's frames since the streak began, to replace what was recorded
        /// for the old holder if the switch is confirmed.
        var frames: [PossessionFrame]
        /// `record.frames.count` when the streak began.
        let recordIndex: Int
    }
    private var streak: Streak?

    init(config: Config = Config()) {
        self.config = config
        self.record = PossessionRecord(config: config)
    }

    /// Move on to `frameID`.
    ///
    /// - Parameters:
    ///   - ball: the ball's centre on this frame, or nil if it wasn't seen.
    ///   - players: the tracks to consider — the visible ones.
    mutating func update(frameID: Int, timeSeconds: Double?, ball: CGPoint?, players: [PlayerTrack]) {
        let tracks = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Lapses first, so a gone holder can't be recorded on this frame.
        if let holderID, tracks[holderID] == nil {
            endPossession(forgettingLastHolder: false)
        }
        if ball != nil {
            lastBallFrame = frameID
        } else if let lastBallFrame, frameID - lastBallFrame > config.maxUnseenFrames {
            endPossession(forgettingLastHolder: true)
        }

        if let ball {
            decide(ball: ball, tracks: tracks, players: players, frameID: frameID, timeSeconds: timeSeconds)
        } else if var current = streak, let challenger = tracks[current.playerID] {
            // An unseen ball doesn't count towards a streak, or break it. If the switch
            // goes through, these frames were the new holder's too.
            current.frames.append(PossessionFrame(
                frameID: frameID, timeSeconds: timeSeconds,
                playerID: challenger.id, box: challenger.box, ballSeen: false
            ))
            streak = current
        }

        // `decide` may have confirmed a switch and written this frame already.
        if let holderID, let holder = tracks[holderID], record.frames.last?.frameID != frameID {
            record.frames.append(PossessionFrame(
                frameID: frameID, timeSeconds: timeSeconds,
                playerID: holderID, box: holder.box, ballSeen: ball != nil
            ))
        }
    }

    // MARK: Deciding

    private mutating func decide(
        ball: CGPoint,
        tracks: [Int: PlayerTrack],
        players: [PlayerTrack],
        frameID: Int,
        timeSeconds: Double?
    ) {
        guard let candidate = bestCandidate(for: ball, among: players) else {
            // Out of everyone's reach: loose, and credited to whoever had it.
            streak = nil
            if let holderID {
                lastHolderID = holderID
                self.holderID = nil
            }
            return
        }

        if candidate.id == holderID {
            streak = nil
            return
        }

        // The last holder taking back a loose ball isn't a change of hands.
        if holderID == nil, candidate.id == lastHolderID {
            streak = nil
            holderID = candidate.id
            return
        }

        let sighting = PossessionFrame(
            frameID: frameID, timeSeconds: timeSeconds,
            playerID: candidate.id, box: candidate.box, ballSeen: true
        )

        var current = streak?.playerID == candidate.id
            ? streak!
            : Streak(playerID: candidate.id, sightings: 0, frames: [], recordIndex: record.frames.count)
        current.sightings += 1
        current.frames.append(sighting)

        guard current.sightings >= config.sightingsToSwitch else {
            streak = current
            return
        }

        // Confirmed. The streak's frames were the new holder's all along.
        record.frames.removeSubrange(current.recordIndex...)
        record.frames.append(contentsOf: current.frames)

        lastHolderID = holderID ?? lastHolderID
        holderID = candidate.id
        streak = nil
    }

    /// The player with the ball within reach whose actual box is nearest it. The current
    /// holder — or, while the ball is loose, the last one — wins a tie.
    private func bestCandidate(for ball: CGPoint, among players: [PlayerTrack]) -> PlayerTrack? {
        let favoured = holderID ?? lastHolderID

        return players
            .filter { reach(of: $0.box).contains(ball) }
            .min { lhs, rhs in
                let left = ranking(lhs, ball: ball, favoured: favoured)
                let right = ranking(rhs, ball: ball, favoured: favoured)
                return left < right
            }
    }

    private func ranking(_ track: PlayerTrack, ball: CGPoint, favoured: Int?) -> (CGFloat, Int, CGFloat) {
        (
            Self.distance(from: ball, to: track.box),
            track.id == favoured ? 0 : 1,
            hypot(ball.x - track.box.midX, ball.y - track.box.midY)
        )
    }

    /// A box grown to how far a player can hold the ball from it. Vision space, so "up"
    /// is +y.
    func reach(of box: CGRect) -> CGRect {
        CGRect(
            x: box.minX - box.width * config.reachSide,
            y: box.minY - box.height * config.reachDown,
            width: box.width * (1 + 2 * config.reachSide),
            height: box.height * (1 + config.reachDown + config.reachUp)
        )
    }

    /// Distance from a point to a box: zero inside it.
    private static func distance(from point: CGPoint, to box: CGRect) -> CGFloat {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return hypot(dx, dy)
    }

    private mutating func endPossession(forgettingLastHolder: Bool) {
        if let holderID, !forgettingLastHolder {
            lastHolderID = holderID
        }
        holderID = nil
        streak = nil
        if forgettingLastHolder {
            lastHolderID = nil
        }
    }
}
