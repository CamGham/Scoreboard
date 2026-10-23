//
//  ShooterLocator.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import Foundation

/// Who took a shot, when it left their hands, and where they took off from.
struct ShooterSighting: Codable, Equatable {
    /// The shooter's `PlayerTrack` id — only meaningful within the run that produced it.
    let playerID: Int

    /// The last frame the shooter held the ball.
    let releaseFrame: Int
    let releaseTime: Double?

    /// The shooter's box at release, in Vision normalized space.
    let releaseBox: CGRect

    /// The frame their feet were last on the floor, and where: the bottom-centre of their
    /// box then. This is the shot's location.
    let takeOffFrame: Int
    let takeOffTime: Double?
    let takeOffPoint: CGPoint
}

/// Reads an attempt's shooter out of the possession record.
///
/// The possession tracker has already decided, frame by frame, whether the ball was
/// within someone's reach. By the time an attempt opens the ball has been loose for
/// several sightings, so the last held frame before it is the release, and its holder
/// is the shooter.
enum ShooterLocator {

    struct Config: Codable, Equatable {
        /// A release further back than this before the attempt opened is too stale to
        /// trust — a late-detected attempt, or possession that lapsed — so no shooter is
        /// recorded. About a second and a half at 30 fps.
        var maxReleaseAgeFrames = 45

        /// How far before release to look for take-off. Half a second at 30 fps.
        var takeOffWindowFrames = 15
    }

    /// - Parameter openedAt: the frame the attempt opened on.
    static func locate(
        in record: PossessionRecord,
        openedAt: Int,
        config: Config = Config()
    ) -> ShooterSighting? {

        guard let releaseIndex = record.lastIndex(atOrBefore: openedAt) else { return nil }
        let release = record.frames[releaseIndex]

        guard openedAt - release.frameID <= config.maxReleaseAgeFrames else { return nil }

        // On a jump shot the feet leave the floor before the ball leaves the hands, so
        // the box bottom rises. Its lowest point in the run-up is the last floor contact.
        // Only the shooter's own frames count, and only back to where their touch began.
        let earliest = release.frameID - config.takeOffWindowFrames
        var takeOff = release
        var index = releaseIndex
        while index >= 0,
              record.frames[index].playerID == release.playerID,
              record.frames[index].frameID >= earliest {
            let frame = record.frames[index]
            if frame.box.minY < takeOff.box.minY {
                takeOff = frame
            }
            index -= 1
        }

        return ShooterSighting(
            playerID: release.playerID,
            releaseFrame: release.frameID,
            releaseTime: release.timeSeconds,
            releaseBox: release.box,
            takeOffFrame: takeOff.frameID,
            takeOffTime: takeOff.timeSeconds,
            takeOffPoint: CGPoint(x: takeOff.box.midX, y: takeOff.box.minY)
        )
    }
}

extension ShooterLocator.Config {
    // Lenient, so settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        maxReleaseAgeFrames = try container.decode(.maxReleaseAgeFrames, or: defaults.maxReleaseAgeFrames)
        takeOffWindowFrames = try container.decode(.takeOffWindowFrames, or: defaults.takeOffWindowFrames)
    }
}
