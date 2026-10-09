//
//  PlayerTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 09/10/2026.
//

import Foundation
import LASwift

/// One player the tracker is following.
struct PlayerTrack: Identifiable, Equatable {

    enum State: Equatable {
        /// Seen, but not yet on enough consecutive passes to be trusted. Not drawn.
        case tentative
        /// Matched on the most recent pass.
        case confirmed
        /// Confirmed, but missed since — carried forward on its prediction until it is
        /// matched again or has been gone too long.
        case coasting
    }

    /// Stable for as long as the track lives. Shown as "P\(id)".
    let id: Int

    /// Current estimate: the detection's box smoothed on a matched frame, the predicted
    /// box otherwise.
    var box: CGRect

    /// Centre velocity per frame, in Vision normalized space.
    var velocity: CGVector

    var state: State

    /// Confidence of the detection it was last matched to.
    var confidence: Float

    var firstFrame: Int
    var lastSeenFrame: Int

    /// Passes it has been matched on.
    var hits: Int

    var isVisible: Bool { state != .tentative }
}

/// Follows players across frames from detections that only arrive every few frames.
///
/// Replaces `VNTrackObjectRequest`. That tracker followed appearance from frame to frame,
/// drifted onto the background, held at most six objects and never noticed a player who
/// walked in. Here the detector finds the players and this only decides which detection
/// belongs to which player:
///
/// 1. Every track's box is moved forward with its `BoxKalmanFilter` — on every frame, so
///    boxes keep moving between detections.
/// 2. On a frame with detections, each track is matched to a detection by overlap with
///    where the track was *predicted* to be, solved optimally with the Hungarian
///    algorithm. Matching against the prediction rather than the last sighting is what
///    keeps two players' identities apart as they cross.
/// 3. Confident detections are matched first. Tracks still unmatched then get a second
///    chance against weaker ones — a partly hidden player scores lower, and this keeps
///    them followed. A weak detection never starts a track of its own.
/// 4. A new track has to be matched on consecutive passes before it is shown, and a
///    confirmed one coasts on its prediction through short gaps before it is dropped.
///
/// Time is counted in frames, like the shot detector.
struct PlayerTracker {

    struct Config: Codable, Equatable {
        /// Run player detection on every this-many frames. Sweeps by the ball detector
        /// add detections in between for free.
        var detectionInterval = 3

        /// Confidence a detection needs to start a track, or to be matched first.
        var highConfidence: Float = 0.6

        /// Below this a detection is ignored. Between this and `highConfidence` it can
        /// only keep an existing track alive.
        var lowConfidence: Float = 0.25

        /// Least overlap between a prediction and a detection for them to match.
        var minimumOverlap: CGFloat = 0.3

        /// Consecutive matched passes before a new track is shown.
        var passesToConfirm = 2

        /// Frames a confirmed track may go unmatched before it is dropped. About a second
        /// at 30 fps — long enough to carry a player through a screen.
        var maxCoastFrames = 30
    }

    let config: Config

    private(set) var tracks: [PlayerTrack] = []

    /// Tracks that ever became confirmed. With a fixed set of people on court this
    /// ideally equals the head count; anything more means identities broke and restarted.
    private(set) var tracksConfirmed = 0

    /// Frames spanned by confirmed tracks that have since ended, and how many ended —
    /// the average lifetime, another view of how often identities break.
    private(set) var endedTrackFrames = 0
    private(set) var endedTracks = 0

    private var filters: [Int: BoxKalmanFilter] = [:]
    private var nextID = 1
    private var lastFrame: Int?

    /// Cost given to a pairing that fails the overlap gate. Large rather than infinite:
    /// the solver must still be able to make it when nothing else is left, and such a
    /// pairing is discarded afterwards — but it is never preferred over a real match.
    private static let gatedCost = 1e6

    init(config: Config = Config()) {
        self.config = config
    }

    /// Tracks worth drawing: confirmed and coasting.
    var visibleTracks: [PlayerTrack] { tracks.filter(\.isVisible) }

    /// Whether this frame is due a player detection pass.
    func isDetectionDue(frameID: Int) -> Bool {
        config.detectionInterval > 0 && frameID % config.detectionInterval == 0
    }

    /// Advance to `frameID`, folding in `detections` if this frame had any.
    ///
    /// - Parameter detections: nil on a frame without a detection pass, where tracks only
    ///   move forward on their predictions. An empty array is a pass that found nobody,
    ///   which counts as a miss for every track.
    mutating func update(frameID: Int, detections: [PlayerDetection]?) {
        predict(to: frameID)

        guard let detections else {
            drop(at: frameID)
            return
        }

        let high = detections.filter { $0.confidence >= config.highConfidence }
        let low = detections.filter {
            $0.confidence >= config.lowConfidence && $0.confidence < config.highConfidence
        }

        // Round one: every track against the confident detections.
        let first = match(trackIndices: Array(tracks.indices), to: high)

        // Round two: established tracks that missed get a chance at the weak ones.
        // Tentative tracks don't — a weak detection is no evidence for something that
        // hasn't proved itself yet.
        let unmatchedEstablished = first.unmatchedTracks.filter { tracks[$0].state != .tentative }
        let second = match(trackIndices: unmatchedEstablished, to: low)

        for (trackIndex, detection) in first.pairs.map({ ($0.track, high[$0.detection]) })
            + second.pairs.map({ ($0.track, low[$0.detection]) }) {
            apply(detection, toTrackAt: trackIndex, frameID: frameID)
        }

        // A tentative track has to be matched on consecutive passes, so a single miss
        // ends it. A confirmed one coasts.
        let matched = Set(first.pairs.map(\.track) + second.pairs.map(\.track))
        var abandoned = Set<Int>()
        for index in tracks.indices where !matched.contains(index) {
            if tracks[index].state == .tentative {
                abandoned.insert(tracks[index].id)
            } else {
                tracks[index].state = .coasting
            }
        }

        drop(at: frameID, abandoning: abandoned)

        for index in first.unmatchedDetections {
            start(high[index], at: frameID)
        }
    }

    /// Forget everything, as at the start of a new clip.
    mutating func reset() {
        self = PlayerTracker(config: config)
    }

    // MARK: Steps

    private mutating func predict(to frameID: Int) {
        defer { lastFrame = frameID }
        guard let lastFrame else { return }

        let frames = frameID - lastFrame
        guard frames > 0 else { return }

        for index in tracks.indices {
            let id = tracks[index].id
            guard var filter = filters[id] else { continue }

            filter.predict(frames: frames)
            filters[id] = filter

            tracks[index].box = filter.box
            tracks[index].velocity = filter.velocity
        }
    }

    private mutating func apply(_ detection: PlayerDetection, toTrackAt index: Int, frameID: Int) {
        let id = tracks[index].id
        guard var filter = filters[id] else { return }

        filter.update(with: detection.boundingBox)
        filters[id] = filter

        tracks[index].box = filter.box
        tracks[index].velocity = filter.velocity
        tracks[index].confidence = detection.confidence
        tracks[index].lastSeenFrame = frameID
        tracks[index].hits += 1

        if tracks[index].state == .tentative {
            if tracks[index].hits >= config.passesToConfirm {
                tracks[index].state = .confirmed
                tracksConfirmed += 1
            }
        } else {
            tracks[index].state = .confirmed
        }
    }

    private mutating func start(_ detection: PlayerDetection, at frameID: Int) {
        let id = nextID
        nextID += 1

        let filter = BoxKalmanFilter(box: detection.boundingBox)
        filters[id] = filter

        var track = PlayerTrack(
            id: id,
            box: filter.box,
            velocity: filter.velocity,
            state: .tentative,
            confidence: detection.confidence,
            firstFrame: frameID,
            lastSeenFrame: frameID,
            hits: 1
        )

        if config.passesToConfirm <= 1 {
            track.state = .confirmed
            tracksConfirmed += 1
        }

        tracks.append(track)
    }

    /// Remove tracks gone longer than `maxCoastFrames`, plus any named in `abandoned`.
    private mutating func drop(at frameID: Int, abandoning abandoned: Set<Int> = []) {
        tracks.removeAll { track in
            let expired = abandoned.contains(track.id)
                || frameID - track.lastSeenFrame > config.maxCoastFrames
            guard expired else { return false }

            if track.state != .tentative {
                endedTracks += 1
                endedTrackFrames += track.lastSeenFrame - track.firstFrame
            }
            filters[track.id] = nil
            return true
        }
    }

    // MARK: Matching

    private struct Matching {
        var pairs: [(track: Int, detection: Int)] = []
        var unmatchedTracks: [Int] = []
        var unmatchedDetections: [Int] = []
    }

    /// Optimal one-to-one pairing of the given tracks with `detections` by overlap with
    /// each track's predicted box. Pairs below `minimumOverlap` are left unmatched.
    private func match(trackIndices: [Int], to detections: [PlayerDetection]) -> Matching {
        guard !trackIndices.isEmpty, !detections.isEmpty else {
            return Matching(
                unmatchedTracks: trackIndices,
                unmatchedDetections: Array(detections.indices)
            )
        }

        let overlaps: [[CGFloat]] = trackIndices.map { trackIndex in
            detections.map { tracks[trackIndex].box.intersectionOverUnion(with: $0.boundingBox) }
        }

        let costs = Matrix(overlaps.map { row in
            Vector(row.map { $0 >= config.minimumOverlap ? 1 - Double($0) : Self.gatedCost })
        })

        guard let assignment = try? HungarianAlgorithm.findOptimalAssignment(costs) else {
            return Matching(
                unmatchedTracks: trackIndices,
                unmatchedDetections: Array(detections.indices)
            )
        }

        var result = Matching()
        var usedRows = Set<Int>()
        var usedColumns = Set<Int>()

        for (row, column) in zip(assignment.rowIndices, assignment.columnIndices)
        where overlaps[row][column] >= config.minimumOverlap {
            result.pairs.append((track: trackIndices[row], detection: column))
            usedRows.insert(row)
            usedColumns.insert(column)
        }

        result.unmatchedTracks = trackIndices.indices
            .filter { !usedRows.contains($0) }
            .map { trackIndices[$0] }
        result.unmatchedDetections = detections.indices.filter { !usedColumns.contains($0) }

        return result
    }
}
