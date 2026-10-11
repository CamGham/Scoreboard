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

    /// Playback position, in media seconds.
    let time: Double

    var body: some View {
        GeometryReader { geometry in
            if let holder = possession?.frame(atTime: time) {
                let size = geometry.size

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
