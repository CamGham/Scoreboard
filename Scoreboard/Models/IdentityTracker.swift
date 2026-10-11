//
//  IdentityTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import Foundation
import LASwift

/// What kind of session a clip shows, which says how many people are on court.
enum GameFormat: String, Codable, CaseIterable, Identifiable {
    case shootaround
    case oneOnOne
    case twoOnTwo
    case threeOnThree
    case fourOnFour
    case fiveOnFive

    var id: Self { self }

    var playerCount: Int {
        switch self {
        case .shootaround: 1
        case .oneOnOne: 2
        case .twoOnTwo: 4
        case .threeOnThree: 6
        case .fourOnFour: 8
        case .fiveOnFive: 10
        }
    }

    var title: String {
        switch self {
        case .shootaround: "Shootaround"
        case .oneOnOne: "1v1"
        case .twoOnTwo: "2v2"
        case .threeOnThree: "3v3"
        case .fourOnFour: "4v4"
        case .fiveOnFive: "5v5"
        }
    }
}

/// One person on court, for the length of one clip.
struct PlayerIdentity: Codable, Equatable, Identifiable {
    let id: UUID

    /// 1-based, in the order players were first seen. Shown as "P\(number)" until named.
    let number: Int

    /// A name the user gives the player. Nil until then.
    var displayName: String?

    var label: String { displayName ?? "P\(number)" }
}

/// A stretch of one track that was one player.
struct IdentitySegment: Codable, Equatable {
    let trackID: Int
    let playerID: UUID

    /// The track's first frame. A track that claims a player late is still that player
    /// from the start: it was following them all along.
    let startFrame: Int

    /// The track's last matched frame so far. Coasting frames after it are guesses.
    var endFrame: Int
}

/// Which track was which player, over the run.
///
/// Everything else in the run — possession, the shooter — records track ids. This sits
/// beside them rather than being written into them, so a decision about who a track was
/// can change after the fact without rewriting those records.
struct IdentityRecord: Codable, Equatable {
    var format: GameFormat
    var players: [PlayerIdentity]
    var segments: [IdentitySegment] = []

    /// The player `trackID` was on `frameID`: the latest of its segments starting on or
    /// before then. Frames past a segment's end still count — the track was coasting, and
    /// was nobody else.
    func player(forTrack trackID: Int, at frameID: Int) -> PlayerIdentity? {
        guard let segment = segments
            .filter({ $0.trackID == trackID && $0.startFrame <= frameID })
            .max(by: { $0.startFrame < $1.startFrame })
        else { return nil }

        return players.first { $0.id == segment.playerID }
    }
}

/// Puts the player tracks onto a fixed set of people.
///
/// `PlayerTracker` follows boxes from frame to frame, and when it loses one — an overlap,
/// a player hidden for longer than it coasts — the box comes back as a new track. Tracks
/// are allowed to break; this decides which person each one is.
///
/// The format the user picked says how many people there are, so the set is closed:
///
/// - Each new track claims a **free** player — one whose track has ended. In a 1v1, a
///   third track has to be one of the two.
/// - A player last seen recently can only be claimed by a track **near where they
///   were**. The allowance grows with the time they have been gone.
/// - A player seen before is preferred to one never seen: a track that fits someone who
///   just disappeared is more likely them than a newcomer.
/// - With every player held, a new track gets nobody — a duplicate box or a bystander —
///   and waits, in case one comes free.
///
/// Time is counted in frames, like the player tracker.
struct IdentityTracker {

    struct Config: Codable, Equatable {
        /// How far from a player's last sighting a track can claim them with no time gone,
        /// in Vision normalized units: room for box jitter and smoothing.
        var reachSlack: CGFloat = 0.1

        /// How much further each frame gone adds. About 0.6 of the frame's width a second
        /// at 30 fps — more than a sprint across a half-court view.
        var maxSpeedPerFrame: CGFloat = 0.02
    }

    /// Numbers for the run, to judge whether identities held.
    struct Summary: Codable, Equatable {
        var playerCount: Int

        /// Players a track ever claimed. Fewer than `playerCount` means someone was never
        /// seen, or never got a track of their own.
        var playersSeen = 0

        /// Times a player passed to a new track. Each is a break the tracker made that
        /// this joined back up.
        var relinks = 0

        /// Confirmed tracks that never got a player.
        var unassignedTracks = 0
    }

    let config: Config

    private(set) var record: IdentityRecord

    /// What is known about each player, in the same order as `record.players`.
    private struct Slot {
        /// The track that is this player now.
        var owner: Int?

        /// Where they were last matched, and when. Nil until first claimed.
        var lastBox: CGRect?
        var lastSeenFrame: Int?
    }
    private var slots: [Slot]

    /// For each track holding a player: which one, and its segment in `record.segments`.
    private var assignments: [Int: (player: Int, segment: Int)] = [:]

    /// Live tracks with no player.
    private var unassigned: Set<Int> = []

    private var relinks = 0
    private var endedUnassigned = 0

    /// Cost given to a pairing that fails the distance check — see `PlayerTracker`.
    private static let gatedCost = 1e6

    init(format: GameFormat, config: Config = Config()) {
        self.config = config
        self.record = IdentityRecord(
            format: format,
            players: (1...format.playerCount).map { PlayerIdentity(id: UUID(), number: $0) }
        )
        self.slots = Array(repeating: Slot(), count: format.playerCount)
    }

    var summary: Summary {
        Summary(
            playerCount: slots.count,
            playersSeen: slots.filter { $0.lastSeenFrame != nil }.count,
            relinks: relinks,
            unassignedTracks: endedUnassigned + unassigned.count
        )
    }

    /// The player each track is, by track id. A track missing from it has nobody yet.
    func labels(for tracks: [PlayerTrack]) -> [Int: String] {
        var labels: [Int: String] = [:]
        for track in tracks {
            if let assignment = assignments[track.id] {
                labels[track.id] = record.players[assignment.player].label
            }
        }
        return labels
    }

    /// Move on to `frameID`.
    ///
    /// - Parameter tracks: the tracks worth showing — confirmed and coasting. One that was
    ///   here before and isn't now has ended.
    mutating func update(frameID: Int, tracks: [PlayerTrack]) {
        let live = Set(tracks.map(\.id))

        // Ended tracks free their players.
        for (trackID, assignment) in assignments where !live.contains(trackID) {
            slots[assignment.player].owner = nil
            assignments[trackID] = nil
        }
        let endedWaiting = unassigned.subtracting(live)
        endedUnassigned += endedWaiting.count
        unassigned.subtract(endedWaiting)

        // Only a matched frame says where a player is. A coasting box is a prediction.
        for track in tracks {
            guard let assignment = assignments[track.id] else {
                unassigned.insert(track.id)
                continue
            }
            guard track.lastSeenFrame == frameID else { continue }

            slots[assignment.player].lastBox = track.box
            slots[assignment.player].lastSeenFrame = frameID
            record.segments[assignment.segment].endFrame = frameID
        }

        assignFreePlayers(to: tracks.filter { unassigned.contains($0.id) }, at: frameID)
    }

    // MARK: Assigning

    private mutating func assignFreePlayers(to waiting: [PlayerTrack], at frameID: Int) {
        guard !waiting.isEmpty else { return }

        // Oldest first, so the first players seen are the lowest numbers.
        let waiting = waiting.sorted { ($0.firstFrame, $0.id) < ($1.firstFrame, $1.id) }
        let free = slots.indices.filter { slots[$0].owner == nil }
        let seen = free.filter { slots[$0].lastSeenFrame != nil }
        let unseen = free.filter { slots[$0].lastSeenFrame == nil }

        // Players seen before, matched to the tracks nearest where they were.
        var claimed = Set<Int>()
        for (trackIndex, player) in match(waiting, to: seen, at: frameID) {
            claim(player: player, by: waiting[trackIndex])
            claimed.insert(trackIndex)
        }

        // Whoever is left takes a player nobody has seen yet, in order.
        let remaining = waiting.indices.filter { !claimed.contains($0) }
        for (trackIndex, player) in zip(remaining, unseen) {
            claim(player: player, by: waiting[trackIndex])
        }
    }

    /// Optimal pairing of tracks with players by distance from each player's last
    /// sighting. Pairs that fail the distance check are left out.
    private func match(_ tracks: [PlayerTrack], to players: [Int], at frameID: Int) -> [(track: Int, player: Int)] {
        guard !tracks.isEmpty, !players.isEmpty else { return [] }

        let distances: [[CGFloat?]] = tracks.map { track in
            players.map { distance(from: slots[$0], to: track, at: frameID) }
        }

        let costs = Matrix(distances.map { row in
            Vector(row.map { $0.map(Double.init) ?? Self.gatedCost })
        })

        guard let assignment = try? HungarianAlgorithm.findOptimalAssignment(costs) else {
            return []
        }

        var pairs: [(track: Int, player: Int)] = []
        for (row, column) in zip(assignment.rowIndices, assignment.columnIndices)
        where distances[row][column] != nil {
            pairs.append((track: row, player: players[column]))
        }
        return pairs
    }

    /// How far `track` is from where the player was last matched, or nil if they couldn't
    /// have got there in the time since.
    private func distance(from slot: Slot, to track: PlayerTrack, at frameID: Int) -> CGFloat? {
        guard let lastBox = slot.lastBox, let lastSeenFrame = slot.lastSeenFrame else { return nil }

        let distance = hypot(track.box.midX - lastBox.midX, track.box.midY - lastBox.midY)
        let allowance = config.reachSlack + config.maxSpeedPerFrame * CGFloat(frameID - lastSeenFrame)
        return distance <= allowance ? distance : nil
    }

    private mutating func claim(player index: Int, by track: PlayerTrack) {
        // Claimed before means a track broke and this one carries on from it.
        if slots[index].lastSeenFrame != nil {
            relinks += 1
        }

        slots[index].owner = track.id
        slots[index].lastBox = track.box
        slots[index].lastSeenFrame = track.lastSeenFrame

        record.segments.append(IdentitySegment(
            trackID: track.id,
            playerID: record.players[index].id,
            startFrame: track.firstFrame,
            endFrame: track.lastSeenFrame
        ))
        assignments[track.id] = (player: index, segment: record.segments.count - 1)
        unassigned.remove(track.id)
    }
}
