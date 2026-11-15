//
//  PossessionRingOverlay.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import SwiftUI

/// A ring on the floor under whoever has the ball, drawn over replayed footage.
///
/// Read from the possession record saved with the run — nothing is re-detected. Lay it
/// out over the picture's content rect, like `ShotTrajectoryOverlay`.
struct PossessionRingOverlay: View {
    let possession: PossessionRecord?

    /// Which track was which player, to name the holder above their head. Nil draws the
    /// ring alone.
    var identities: IdentityRecord?

    /// Playback position, in media seconds.
    let time: Double

    var body: some View {
        GeometryReader { geometry in
            if let holder = possession?.frame(atTime: time) {
                let size = geometry.size

                if let player = identities?.player(forTrack: holder.playerID, at: holder.frameID) {
                    Text(player.label)
                        .font(.caption.bold())
                        .foregroundStyle(Color.orange)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .position(
                            x: holder.box.midX * size.width,
                            y: (1 - holder.box.maxY) * size.height - 10
                        )
                }

                // Under their feet: the bottom-centre of their box, flattened for the
                // camera looking down at the floor.
                let width = holder.box.width * size.width * 1.3
                let feet = CGPoint(
                    x: holder.box.midX * size.width,
                    y: (1 - holder.box.minY) * size.height
                )

                Ellipse()
                    .stroke(Color.orange, lineWidth: 3)
                    .background(Ellipse().fill(Color.orange.opacity(0.2)))
                    .frame(width: width, height: width * 0.35)
                    .position(feet)
            }
        }
        .allowsHitTesting(false)
    }
}
