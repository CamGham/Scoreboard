//
//  PipelineSignpost.swift
//  Scoreboard
//
//  Created by Cam Graham on 02/10/2026.
//

import Foundation
import os

/// Timing for each stage of frame analysis, shown in Instruments' Points of Interest.
///
/// Analysis runs every stage back to back on one thread, so knowing which stage a frame's
/// time goes to is the only way to tell what is worth speeding up — the model, the
/// trackers, or the work around them. Signposts cost next to nothing when Instruments
/// isn't recording, so these stay in.
enum PipelineSignpost {

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Scoreboard",
        category: .pointsOfInterest
    )

    /// Run `body` inside a named interval.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name, id: signposter.makeSignpostID(), around: body)
    }
}
