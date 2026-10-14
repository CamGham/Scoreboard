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

    /// Where the stretch begins: the track's first frame — a track that claims a player
    /// late was following them all along — or, after a check swapped players, the frame
    /// they first touched.
    let startFrame: Int

    /// The track's last matched frame so far. Coasting frames after it are guesses.
    var endFrame: Int
}

/// A stretch where players touched and appearance couldn't settle who came out as whom.
/// The labels are a best guess there.
struct UncertainStretch: Codable, Equatable {
    let startFrame: Int
    let endFrame: Int
    let playerIDs: [UUID]
}

/// One time players touched and were checked — or couldn't be — afterwards.
struct IdentityCheck: Codable, Equatable {
    enum Outcome: String, Codable {
        /// Appearance said the labels were right.
        case kept
        /// Appearance said they came out the other way round, so they were swapped.
        case swapped
        /// Neither way round fitted clearly better. Labels left as a guess.
        case tooClose
        /// Not enough clean samples before the timeout. Labels left as a guess.
        case neverClear
        /// Someone touched before there was a clean look at them to compare with.
        case noEarlierLook
    }

    /// When the players first touched, and when it was settled.
    let startFrame: Int
    let frame: Int
    let startTime: Double?
    let time: Double?

    let playerIDs: [UUID]
    let outcome: Outcome

    /// Total distance between looks with the labels as they were, and with the best other
    /// way round. Nil when it never got as far as comparing.
    let keepCost: Double?
    let otherCost: Double?

    /// Clean samples each player's track had gathered, in `playerIDs` order.
    let samples: [Int]

    /// Why each player did or didn't give a clean sample on each frame with detections
    /// since they last touched, in `playerIDs` order. Nil for checks from before it was
    /// recorded.
    let blocked: [Blocked]?

    /// One player's frames after a touch, by the first thing that kept each from being a
    /// clean sample — the same rules `AppearanceSeparation.cleanTracks` applies.
    struct Blocked: Codable, Equatable {
        /// Sampled.
        var clean = 0
        /// No track was this player.
        var noTrack = 0
        /// Their track was coasting: no detection matched it.
        var notMatched = 0
        /// Matched, but below the confidence a sample needs.
        var lowConfidence = 0
        /// Clear of the other players, but touching a box that is nobody — a duplicate
        /// or a bystander.
        var touchingNobody = 0
    }
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

    /// Where the labels are a guess, for the user to check.
    var uncertain: [UncertainStretch] = []

    /// Every check after players touched, whatever came of it.
    var checks: [IdentityCheck] = []

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

extension IdentityRecord {
    // Runs saved before uncertain stretches were recorded have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(GameFormat.self, forKey: .format)
        players = try container.decode([PlayerIdentity].self, forKey: .players)
        segments = try container.decodeIfPresent([IdentitySegment].self, forKey: .segments) ?? []
        uncertain = try container.decodeIfPresent([UncertainStretch].self, forKey: .uncertain) ?? []
        checks = try container.decodeIfPresent([IdentityCheck].self, forKey: .checks) ?? []
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
/// Position can't say who is who when players touch: they come out of it at the same
/// spot, and the tracker may swap them or lose both. So players who touch are **grouped**
/// until it is settled, through any breaks and relinks. Once they are apart, each one's
/// track gathers a few clean samples, and those are compared with how each player looked
/// just before the touch. If the other way round fits clearly better, they are swapped
/// from the frame they first touched. If neither fits clearly better, the check waits for
/// more samples and asks again; still unclear at the limit, the labels stay and the
/// stretch is marked uncertain.
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

        /// Clean samples each player's track needs after a touch before it is checked.
        /// About 0.4 s with a detection pass every third frame.
        var samplesToCheck = 4

        /// How much closer one way round has to fit than the other to be acted on.
        var clearMargin = 0.25

        /// Clean samples to wait for, at most, when neither way round fits clearly better
        /// yet. About 1.5 s — inside the timeout, so a check that is gathering samples
        /// gets to finish.
        var maxSamplesToCheck = 15

        /// Frames after a touch to wait for those samples before giving up and marking
        /// the stretch uncertain. Three seconds at 30 fps.
        var checkTimeoutFrames = 90
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

        /// Touches settled by appearance, and how many of those swapped players.
        var checks = 0
        var swaps = 0

        /// Touches left as a guess: too close to call, or no clean samples in time.
        var uncertain = 0
    }

    let config: Config

    private(set) var record: IdentityRecord

    /// Samples, tracklets, and how much each cue varies — see `AppearanceSeparation`.
    private(set) var appearance = AppearanceSeparation()

    /// What is known about each player, in the same order as `record.players`.
    private struct Slot {
        /// The track that is this player now.
        var owner: Int?

        /// Where they were last matched, and when. Nil until first claimed.
        var lastBox: CGRect?
        var lastSeenFrame: Int?

        /// How they looked over their last clean stretch while nobody was in doubt about
        /// them — what a check compares against.
        var recentLook: AppearanceSeparation.Look?
    }
    private var slots: [Slot]

    /// For each track holding a player: which one, and its segment in `record.segments`.
    private var assignments: [Int: (player: Int, segment: Int)] = [:]

    /// Live tracks with no player.
    private var unassigned: Set<Int> = []

    /// Players who touched and haven't been checked yet.
    private struct Group {
        var players: Set<Int>
        var startFrame: Int
        var startTime: Double?
        var lastTouchFrame: Int

        /// Since the last touch, by player: why each frame did or didn't give a sample.
        /// A new touch starts it again, since only the final wait matters.
        var blocked: [Int: IdentityCheck.Blocked] = [:]
    }
    private var groups: [Group] = []

    private var relinks = 0
    private var endedUnassigned = 0
    private var checks = 0
    private var swaps = 0
    private var uncertain = 0

    /// Media time of the frame being processed, to stamp checks with.
    private var currentTime: Double?

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
            unassignedTracks: endedUnassigned + unassigned.count,
            checks: checks,
            swaps: swaps,
            uncertain: uncertain
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
    /// - Parameters:
    ///   - timeSeconds: the frame's presentation time, so checks can be found in the video.
    ///   - tracks: the tracks worth showing — confirmed and coasting. One that was here
    ///     before and isn't now has ended.
    ///   - samples: clean appearance samples taken on this frame, by track id.
    mutating func update(
        frameID: Int,
        timeSeconds: Double? = nil,
        tracks: [PlayerTrack],
        samples: [Int: AppearanceSample] = [:]
    ) {
        currentTime = timeSeconds
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

        appearance.update(frameID: frameID, tracks: tracks, samples: samples)

        // Grouped before looks are refreshed, so a touch freezes each player's look as
        // it was just before.
        noteTouches(among: tracks, at: frameID)
        refreshRecentLooks()
        countBlocks(among: tracks, at: frameID)
        checkGroups(tracks: tracks, at: frameID)
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

    // MARK: Touching

    /// Group the players of every set of tracks touching each other on this frame,
    /// merging with any group they are already in.
    private mutating func noteTouches(among tracks: [PlayerTrack], at frameID: Int) {
        let clearance = appearance.config.clearance
        var visited = Set<Int>()

        for start in tracks where !visited.contains(start.id) {
            var cluster: [PlayerTrack] = []
            var queue = [start]
            visited.insert(start.id)

            while let next = queue.popLast() {
                cluster.append(next)
                for other in tracks where !visited.contains(other.id)
                    && AppearanceSeparation.touches(next, other, clearance: clearance) {
                    visited.insert(other.id)
                    queue.append(other)
                }
            }

            let players = Set(cluster.compactMap { assignments[$0.id]?.player })
            guard players.count >= 2 else { continue }
            join(players, at: frameID)
        }
    }

    private mutating func join(_ players: Set<Int>, at frameID: Int) {
        var merged = Group(players: players, startFrame: frameID, startTime: currentTime, lastTouchFrame: frameID)
        groups.removeAll { group in
            guard !group.players.isDisjoint(with: players) else { return false }
            merged.players.formUnion(group.players)
            if group.startFrame < merged.startFrame {
                merged.startFrame = group.startFrame
                merged.startTime = group.startTime
            }
            return true
        }
        groups.append(merged)
    }

    /// Take each ungrouped player's look from their track's current tracklet, once it has
    /// enough samples. Grouped players keep the look from before they touched.
    private mutating func refreshRecentLooks() {
        let grouped = groups.reduce(into: Set<Int>()) { $0.formUnion($1.players) }

        for index in slots.indices where !grouped.contains(index) {
            guard let owner = slots[index].owner,
                  let look = appearance.look(ofTrack: owner),
                  look.count >= appearance.config.samplesBeforeComparing
            else { continue }
            slots[index].recentLook = look
        }
    }

    /// For every group waiting after its last touch, note why each player did or didn't
    /// give a clean sample on this frame.
    private mutating func countBlocks(among tracks: [PlayerTrack], at frameID: Int) {
        // Only a frame with a detection pass can give a sample at all.
        guard tracks.contains(where: { $0.lastSeenFrame == frameID }) else { return }

        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rules = appearance.config

        for index in groups.indices where groups[index].lastTouchFrame < frameID {
            for player in groups[index].players {
                var counts = groups[index].blocked[player] ?? IdentityCheck.Blocked()

                if let owner = slots[player].owner, let track = byID[owner] {
                    if track.lastSeenFrame != frameID {
                        counts.notMatched += 1
                    } else if track.confidence < rules.minimumConfidence {
                        counts.lowConfidence += 1
                    } else if tracks.contains(where: {
                        $0.id != track.id && AppearanceSeparation.touches(track, $0, clearance: rules.clearance)
                    }) {
                        // Anyone else's player touching them would have joined this group
                        // and restarted the wait, so this is a box that is nobody.
                        counts.touchingNobody += 1
                    } else {
                        counts.clean += 1
                    }
                } else {
                    counts.noTrack += 1
                }

                groups[index].blocked[player] = counts
            }
        }
    }

    // MARK: Checking

    /// Settle every group whose players are apart and have enough clean samples, and give
    /// up on any that have waited too long.
    private mutating func checkGroups(tracks: [PlayerTrack], at frameID: Int) {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var waiting: [Group] = []

        for group in groups {
            guard group.lastTouchFrame < frameID else {
                waiting.append(group)
                continue
            }

            let ready = group.players.allSatisfy { player in
                guard let owner = slots[player].owner else { return false }
                return (appearance.look(ofTrack: owner)?.count ?? 0) >= config.samplesToCheck
            }

            if ready {
                if !check(group, tracks: byID, at: frameID) {
                    waiting.append(group)
                }
            } else if frameID - group.lastTouchFrame > config.checkTimeoutFrames {
                log(group, at: frameID, outcome: .neverClear)
            } else {
                waiting.append(group)
            }
        }

        groups = waiting
    }

    /// Compare how each player's track looks now with how each player looked before the
    /// touch, and swap them if the other way round fits clearly better.
    ///
    /// - Returns: whether the group is settled. A close call with samples still to come
    ///   isn't: it is asked again with each new one, and only logged once it is clear or
    ///   has reached `maxSamplesToCheck`.
    private mutating func check(_ group: Group, tracks byID: [Int: PlayerTrack], at frameID: Int) -> Bool {
        struct Entry {
            let player: Int
            let track: PlayerTrack
            let now: AppearanceSeparation.Look
            let before: AppearanceSeparation.Look
        }

        let entries: [Entry] = group.players.sorted().compactMap { player in
            guard let owner = slots[player].owner,
                  let track = byID[owner],
                  let now = appearance.look(ofTrack: owner),
                  let before = slots[player].recentLook
            else { return nil }
            return Entry(player: player, track: track, now: now, before: before)
        }

        // Someone with no look from before can't be checked.
        guard entries.count == group.players.count, entries.count >= 2 else {
            log(group, at: frameID, outcome: .noEarlierLook)
            return true
        }

        // costs[i][j]: how far entry i's track now is from how entry j's player looked.
        var costs: [[Double]] = []
        for entry in entries {
            var row: [Double] = []
            for other in entries {
                guard let distance = appearance.distance(entry.now, other.before) else {
                    log(group, at: frameID, outcome: .tooClose)
                    return true
                }
                row.append(distance)
            }
            costs.append(row)
        }

        let current = entries.indices.reduce(0) { $0 + costs[$1][$1] }

        // The look now is an average that steadies with every sample, so a close call is
        // worth asking again — up to a point, since each extra look is another chance for
        // noise to tip it. The timeout still applies: a player who stops being clear
        // mustn't leave the check waiting for samples that never come.
        let canWait = (entries.map(\.now.count).min() ?? 0) < config.maxSamplesToCheck
            && frameID - group.lastTouchFrame <= config.checkTimeoutFrames

        if entries.count == 2 {
            let swapped = costs[0][1] + costs[1][0]
            if swapped < current * (1 - config.clearMargin) {
                reassign([(entries[0].track, entries[1].player), (entries[1].track, entries[0].player)], from: group.startFrame)
                swaps += 1
                checks += 1
                log(group, at: frameID, outcome: .swapped, keepCost: current, otherCost: swapped)
            } else if current < swapped * (1 - config.clearMargin) {
                checks += 1
                log(group, at: frameID, outcome: .kept, keepCost: current, otherCost: swapped)
            } else if canWait {
                return false
            } else {
                checks += 1
                log(group, at: frameID, outcome: .tooClose, keepCost: current, otherCost: swapped)
            }
            return true
        }

        guard let assignment = try? HungarianAlgorithm.findOptimalAssignment(
            Matrix(costs.map { Vector($0) })
        ) else {
            log(group, at: frameID, outcome: .tooClose, keepCost: current)
            return true
        }

        let best = zip(assignment.rowIndices, assignment.columnIndices).reduce(0) { $0 + costs[$1.0][$1.1] }
        let changes = zip(assignment.rowIndices, assignment.columnIndices)
            .filter { $0.0 != $0.1 }
            .map { (track: entries[$0.0].track, player: entries[$0.1].player) }

        if changes.isEmpty {
            checks += 1
            log(group, at: frameID, outcome: .kept, keepCost: current, otherCost: best)
        } else if best < current * (1 - config.clearMargin) {
            reassign(changes, from: group.startFrame)
            swaps += 1
            checks += 1
            log(group, at: frameID, outcome: .swapped, keepCost: current, otherCost: best)
        } else if canWait {
            return false
        } else {
            checks += 1
            log(group, at: frameID, outcome: .tooClose, keepCost: current, otherCost: best)
        }
        return true
    }

    /// Give each track a different player from `frame` on. A track that started earlier
    /// keeps its old player up to then.
    private mutating func reassign(_ changes: [(track: PlayerTrack, player: Int)], from frame: Int) {
        for (track, player) in changes {
            guard let current = assignments[track.id] else { continue }
            let segment = record.segments[current.segment]
            let playerID = record.players[player].id
            let index: Int

            if segment.startFrame >= frame {
                record.segments[current.segment] = IdentitySegment(
                    trackID: track.id,
                    playerID: playerID,
                    startFrame: segment.startFrame,
                    endFrame: segment.endFrame
                )
                index = current.segment
            } else {
                record.segments[current.segment].endFrame = min(segment.endFrame, frame - 1)
                record.segments.append(IdentitySegment(
                    trackID: track.id,
                    playerID: playerID,
                    startFrame: frame,
                    endFrame: max(segment.endFrame, frame)
                ))
                index = record.segments.count - 1
            }

            assignments[track.id] = (player: player, segment: index)
        }

        // After every segment has moved, since players are trading tracks.
        for (track, player) in changes {
            slots[player].owner = track.id
            slots[player].lastBox = track.box
            slots[player].lastSeenFrame = track.lastSeenFrame
        }
    }

    /// Record how a check came out. Anything short of a clear answer also marks the
    /// stretch uncertain.
    private mutating func log(
        _ group: Group,
        at frameID: Int,
        outcome: IdentityCheck.Outcome,
        keepCost: Double? = nil,
        otherCost: Double? = nil
    ) {
        let players = group.players.sorted()
        let playerIDs = players.map { record.players[$0].id }

        record.checks.append(IdentityCheck(
            startFrame: group.startFrame,
            frame: frameID,
            startTime: group.startTime,
            time: currentTime,
            playerIDs: playerIDs,
            outcome: outcome,
            keepCost: keepCost,
            otherCost: otherCost,
            samples: players.map { player in
                slots[player].owner.flatMap { appearance.look(ofTrack: $0)?.count } ?? 0
            },
            blocked: players.map { group.blocked[$0] ?? IdentityCheck.Blocked() }
        ))

        switch outcome {
        case .kept, .swapped:
            break
        case .tooClose, .neverClear, .noEarlierLook:
            uncertain += 1
            record.uncertain.append(UncertainStretch(
                startFrame: group.startFrame,
                endFrame: frameID,
                playerIDs: playerIDs
            ))
        }
    }
}

extension IdentityTracker.Summary {
    // Runs saved before checks were made have none of their numbers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playerCount = try container.decode(Int.self, forKey: .playerCount)
        playersSeen = try container.decodeIfPresent(Int.self, forKey: .playersSeen) ?? 0
        relinks = try container.decodeIfPresent(Int.self, forKey: .relinks) ?? 0
        unassignedTracks = try container.decodeIfPresent(Int.self, forKey: .unassignedTracks) ?? 0
        checks = try container.decodeIfPresent(Int.self, forKey: .checks) ?? 0
        swaps = try container.decodeIfPresent(Int.self, forKey: .swaps) ?? 0
        uncertain = try container.decodeIfPresent(Int.self, forKey: .uncertain) ?? 0
    }
}
