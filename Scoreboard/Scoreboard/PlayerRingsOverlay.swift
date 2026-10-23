//
//  PlayerRingsOverlay.swift
//  Scoreboard
//
//  Created by Cam Graham on 23/10/2026.
//

import SwiftUI

/// A ring on the floor under every player, named, drawn over replayed footage.
///
/// Read from what the run saved — positions, identities, possession — and nothing is
/// re-detected. Names come from the identity record, so they show the identities as
/// corrected after the run. Whoever has the ball is orange; a track that was nobody is a
/// grey "?"; a box that was only a prediction at the time is faded and dashed.
///
/// Runs saved before positions were recorded have none, and fall back to the holder's
/// ring alone. Lay it out over the picture's content rect, like `ShotTrajectoryOverlay`.
struct PlayerRingsOverlay: View {
    let positions: PlayerPositionRecord?
    let possession: PossessionRecord?
    var identities: IdentityRecord?

    /// Playback position, in media seconds.
    let time: Double

    /// One colour per player, by number; past the end it starts again.
    private static let palette: [Color] = [.blue, .green, .purple, .pink, .teal, .yellow, .indigo, .mint, .cyan, .brown]

    var body: some View {
        if let positions {
            GeometryReader { geometry in
                let holder = possession?.frame(atTime: time)

                ForEach(positions.positions(atTime: time), id: \.trackID) { placed in
                    let player = identities?.player(forTrack: placed.trackID, at: placed.frameID)
                    let isHolder = holder?.playerID == placed.trackID
                    let colour = isHolder
                        ? Color.orange
                        : player.map { Self.palette[($0.number - 1) % Self.palette.count] } ?? .gray

                    ring(
                        under: placed.box,
                        label: player?.label ?? "?",
                        colour: colour,
                        filled: isHolder,
                        faded: placed.coasting,
                        in: geometry.size
                    )
                }
            }
            .allowsHitTesting(false)
        } else {
            PossessionRingOverlay(possession: possession, identities: identities, time: time)
        }
    }

    private func ring(
        under box: CGRect,
        label: String,
        colour: Color,
        filled: Bool,
        faded: Bool,
        in size: CGSize
    ) -> some View {
        // Under their feet: the bottom-centre of their box, flattened for the camera
        // looking down at the floor.
        let width = box.width * size.width * 1.3
        let feet = CGPoint(x: box.midX * size.width, y: (1 - box.minY) * size.height)
        let opacity = faded ? 0.45 : 1

        return ZStack {
            Ellipse()
                .stroke(colour, style: StrokeStyle(lineWidth: 3, dash: faded ? [6, 4] : []))
                .background(Ellipse().fill(colour.opacity(filled ? 0.2 : 0)))
                .frame(width: width, height: width * 0.35)
                .position(feet)

            Text(label)
                .font(.caption.bold())
                .foregroundStyle(colour)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .position(x: box.midX * size.width, y: (1 - box.maxY) * size.height - 10)
        }
        .opacity(opacity)
    }
}
