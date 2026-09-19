//
//  VideoLayout.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation
import ImageIO

/// Where the video image actually sits inside the view showing it.
///
/// An aspect-fit video is letterboxed: the picture occupies only part of its layer, and
/// normalized detection coordinates are relative to the *picture*, not the layer. Drawing
/// the trajectory against the layer's bounds instead would offset and stretch every
/// point, which reads as a tracking failure rather than a layout one.
///
/// Pure, so the mapping can be tested without a player attached.
enum VideoLayout {

    /// Natural size after the track's orientation is applied.
    ///
    /// A quarter-turn swaps width and height. Vision analyses the *oriented* image, so
    /// the overlay has to use the same shape the detector saw.
    static func orientedSize(
        _ natural: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: natural.height, height: natural.width)
        default:
            return natural
        }
    }

    /// The picture's rect within a container, matching `AVLayerVideoGravity.resizeAspect`.
    static func contentRect(for videoSize: CGSize, in container: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }

        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)

        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Normalized Vision point (origin bottom-left, y up) to a point inside the picture.
    static func point(normalized: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + (normalized.x * contentRect.width),
            y: contentRect.minY + ((1 - normalized.y) * contentRect.height)
        )
    }
}

/// Interpolates a ball position at an arbitrary moment between two sightings.
///
/// Playback time advances continuously while sightings are discrete, so the replay
/// marker would otherwise jump frame to frame. Interpolating in *real time* rather than
/// by frame index keeps it honest on variable-frame-rate footage.
func interpolatedBallPosition(
    trajectory: [BallObservation],
    atTime time: Double
) -> CGPoint? {

    let timed = trajectory.compactMap { observation -> (Double, CGPoint)? in
        guard let seconds = observation.timeSeconds else { return nil }
        return (seconds, observation.center)
    }

    guard let first = timed.first, let last = timed.last else { return nil }

    if time <= first.0 { return first.1 }
    if time >= last.0 { return last.1 }

    for index in 1..<timed.count {
        let (t1, p1) = timed[index]
        guard t1 >= time else { continue }

        let (t0, p0) = timed[index - 1]
        let span = t1 - t0
        guard span > 0 else { return p1 }

        let fraction = (time - t0) / span
        return CGPoint(
            x: p0.x + (fraction * (p1.x - p0.x)),
            y: p0.y + (fraction * (p1.y - p0.y))
        )
    }

    return last.1
}
