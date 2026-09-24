//
//  ExclusionZone.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import Foundation

/// A region of the frame where a ball sighting is thrown away.
///
/// The detector answers "is this orange and round", which a bin, a traffic cone, a warm
/// light or a sign on the far wall can all satisfy. Those false positives are fixed in
/// place, so the cheapest thing the user can tell us is *where* they are — and unlike a
/// confidence threshold, it costs nothing anywhere else in the frame.
///
/// This is also the missing half of re-analysis: re-running a window with nothing changed
/// can only produce the answer it produced the first time. A zone is a change to the
/// input, which is what makes running it again worth doing.
///
/// # Assumption: the camera does not move
///
/// A zone is stored in normalized frame coordinates, which only identify a thing in the
/// world while the picture holds still. That is true of a phone on a tripod at the side
/// of a court, which is what this is for.
///
/// It stops being true the moment the footage pans, zooms, or is re-framed to follow the
/// ball. If that is ever supported, a zone has to become either world-anchored (tracked
/// against static features across frames) or defined per-frame by the same transform used
/// to re-frame the picture — and every zone stored under the old assumption has to be
/// treated as unreliable rather than silently reinterpreted.
///
/// TODO: revisit when/if the source video can pan — see the note above.
struct ExclusionZone: Codable, Identifiable, Equatable {

    let id: UUID

    /// Vision-space rect: origin bottom-left, y up, normalized 0–1 against the *oriented*
    /// frame — the same space every ball and rim observation uses.
    var rect: CGRect

    var createdAt: Date

    init(id: UUID = UUID(), rect: CGRect, createdAt: Date = Date()) {
        self.id = id
        self.rect = rect
        self.createdAt = createdAt
    }

    /// Smallest zone worth keeping, as a fraction of the frame. Below this a stray tap
    /// would leave an invisible zone quietly eating sightings.
    static let minimumSide: CGFloat = 0.02

    /// Whether a sighting falls inside this zone.
    ///
    /// Judged on the ball's centre rather than any overlap: a real shot passing in front
    /// of a blocked-out object clips its edges for a frame or two, and dropping those
    /// frames would put a hole in the middle of a trajectory. The centre only enters the
    /// zone when the thing being seen really is in there.
    func excludes(boundingBox: CGRect) -> Bool {
        rect.contains(CGPoint(x: boundingBox.midX, y: boundingBox.midY))
    }

    /// Fit a drawn rect to the frame, upright and no smaller than `minimumSide`.
    static func normalised(_ rect: CGRect) -> CGRect {
        let upright = rect.standardized

        let width = max(min(upright.width, 1), minimumSide)
        let height = max(min(upright.height, 1), minimumSide)

        return CGRect(
            x: min(max(upright.minX, 0), 1 - width),
            y: min(max(upright.minY, 0), 1 - height),
            width: width,
            height: height
        )
    }
}

extension Array where Element == ExclusionZone {

    /// Whether any zone rejects this sighting.
    func exclude(boundingBox: CGRect) -> Bool {
        contains { $0.excludes(boundingBox: boundingBox) }
    }

    /// Add a zone, fitted to the frame. Overlapping zones are left alone — unlike a
    /// re-analysis section, two blocked-out areas that happen to touch are still two
    /// things the user pointed at, and merging them would swallow frame between them.
    func adding(_ rect: CGRect, at date: Date = Date()) -> [ExclusionZone] {
        self + [ExclusionZone(rect: ExclusionZone.normalised(rect), createdAt: date)]
    }
}
