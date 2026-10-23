//
//  PlayerPositions.swift
//  Scoreboard
//
//  Created by Cam Graham on 23/10/2026.
//

import Foundation

/// Where every player track was through a run, for drawing them in replay.
///
/// Recorded on frames with a detection pass only. The boxes on frames in between are
/// the box filter's predictions from those, so storing them would add size, not
/// information; replay slides each track between its recorded entries instead.
///
/// Positions are by track, like the rest of the run. Which player a track was comes from
/// the identity record, so re-solving identities never touches this.
///
/// Kept in its own compressed file beside the run, not in it — see `ShotStore`. It is
/// many times the size of everything else in a run, and only a replay needs it.
struct PlayerPositionRecord: Codable, Equatable {

    struct Config: Equatable {
        /// Longest a track is drawn from its nearest recorded entry, in seconds. Past it,
        /// the track had ended or wasn't seen.
        var maxGap: Double = 0.2

        /// Decimal places boxes are kept to when saved. Four is a tenth of a pixel on a
        /// 1080p frame.
        var decimals = 4
    }

    /// One track on one recorded frame.
    struct Entry: Codable, Equatable {
        let trackID: Int

        /// In Vision normalized space.
        let box: CGRect

        /// Carried on its prediction rather than matched to a detection.
        let coasting: Bool
    }

    struct Frame: Codable, Equatable {
        let frameID: Int
        let time: Double
        let entries: [Entry]

        private enum CodingKeys: String, CodingKey {
            case frameID = "f", time = "s", entries = "e"
        }
    }

    /// A track where it was at a moment in playback.
    struct Placed: Equatable {
        let trackID: Int
        let box: CGRect
        let coasting: Bool

        /// The recorded frame it was read from, for looking up which player it was.
        let frameID: Int
    }

    var frames: [Frame] = []

    /// Note the tracks on a frame. Only frames where some track was matched to a
    /// detection are kept.
    mutating func record(frameID: Int, time: Double?, tracks: [PlayerTrack], config: Config = Config()) {
        guard let time, tracks.contains(where: { $0.lastSeenFrame == frameID }) else { return }

        frames.append(Frame(
            frameID: frameID,
            time: time,
            entries: tracks.map { track in
                Entry(
                    trackID: track.id,
                    box: Self.rounded(track.box, decimals: config.decimals),
                    coasting: track.state == .coasting
                )
            }
        ))
    }

    /// Every track at `time`: slid between the recorded entries either side of it, or
    /// held at the nearest one. A track with no entry within `maxGap` isn't there.
    func positions(atTime time: Double, config: Config = Config()) -> [Placed] {
        guard !frames.isEmpty else { return [] }

        // Latest recorded frame at or before `time`.
        var low = 0
        var high = frames.count - 1
        var before: Int?
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].time <= time {
                before = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let earlier = before.map { frames[$0] }
        let nextIndex = (before ?? -1) + 1
        let later = nextIndex < frames.count ? frames[nextIndex] : nil

        var placed: [Placed] = []
        var seen = Set<Int>()

        if let earlier {
            let laterEntries = Dictionary(
                (later?.entries ?? []).map { ($0.trackID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for entry in earlier.entries {
                if let later, let next = laterEntries[entry.trackID], later.time - earlier.time <= 2 * config.maxGap {
                    let progress = later.time > earlier.time ? (time - earlier.time) / (later.time - earlier.time) : 0
                    placed.append(Placed(
                        trackID: entry.trackID,
                        box: Self.blend(entry.box, next.box, CGFloat(progress)),
                        coasting: entry.coasting && next.coasting,
                        frameID: earlier.frameID
                    ))
                } else if time - earlier.time <= config.maxGap {
                    placed.append(Placed(trackID: entry.trackID, box: entry.box, coasting: entry.coasting, frameID: earlier.frameID))
                } else {
                    continue
                }
                seen.insert(entry.trackID)
            }
        }

        // Tracks that start just after `time`.
        if let later, later.time - time <= config.maxGap {
            for entry in later.entries where !seen.contains(entry.trackID) {
                placed.append(Placed(trackID: entry.trackID, box: entry.box, coasting: entry.coasting, frameID: later.frameID))
            }
        }

        return placed
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    private static func rounded(_ box: CGRect, decimals: Int) -> CGRect {
        let scale = pow(10, CGFloat(decimals))
        func round(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: round(box.minX), y: round(box.minY), width: round(box.width), height: round(box.height))
    }
}

// Short keys and a flat box: the record holds tens of thousands of entries, and every
// character is repeated in each one.
extension PlayerPositionRecord.Entry {
    private enum CodingKeys: String, CodingKey {
        case trackID = "t", box = "b", coasting = "c"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(Int.self, forKey: .trackID)
        let values = try container.decode([CGFloat].self, forKey: .box)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: .box, in: container, debugDescription: "A box needs four values")
        }
        box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        coasting = try container.decodeIfPresent(Bool.self, forKey: .coasting) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackID, forKey: .trackID)
        try container.encode([box.minX, box.minY, box.width, box.height], forKey: .box)
        if coasting {
            try container.encode(true, forKey: .coasting)
        }
    }
}
