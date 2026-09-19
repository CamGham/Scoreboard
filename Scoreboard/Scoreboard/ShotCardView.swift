//
//  ShotCardView.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import SwiftUI

/// Draws a shot's recorded path over a still frame.
///
/// Nothing here is re-detected. `ShotAttempt` already carries every sighting in
/// `trajectory`, the rim it was judged against, and where the ball crossed the scoring
/// plane — so a card is stored data drawn over a decoded frame, no second analysis pass.
struct ShotTrajectoryOverlay: View {
    let attempt: ShotAttempt

    /// Draw only the part of the path that has happened by this moment, in media
    /// seconds. Nil draws the whole thing — what a static card wants.
    var upTo: Double?

    /// Sightings to draw, clipped to `upTo` when replaying.
    private var visible: [BallObservation] {
        guard let upTo else { return attempt.trajectory }
        return attempt.trajectory.filter { ($0.timeSeconds ?? -.infinity) <= upTo }
    }

    /// The crossing marker only appears once the ball has actually got there.
    private var crossingHasHappened: Bool {
        guard let upTo, let crossing = decidingCrossing else { return upTo == nil }
        guard let time = crossing.timeSeconds else { return true }
        return upTo >= time
    }

    /// Normalized Vision point (origin bottom-left, y up) to SwiftUI view point.
    private func point(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                if let rim = attempt.rim {
                    let centre = point(rim.center, in: size)
                    let rx = rim.horizontalRadius * size.width
                    let ry = rim.verticalRadius * size.height

                    Ellipse()
                        .stroke(Color.orange, lineWidth: 2)
                        .frame(width: rx * 2, height: ry * 2)
                        .position(centre)

                    Path { path in
                        path.move(to: CGPoint(x: rim.leftX * size.width, y: centre.y))
                        path.addLine(to: CGPoint(x: rim.rightX * size.width, y: centre.y))
                    }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                // The path the ball actually took.
                Path { path in
                    let points = visible.map { point($0.center, in: size) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for next in points.dropFirst() { path.addLine(to: next) }
                }
                .stroke(
                    resultColour.opacity(0.9),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )

                // Every sighting, so gaps in detection are visible rather than smoothed
                // over by the connecting line.
                ForEach(Array(visible.enumerated()), id: \.offset) { _, observation in
                    Circle()
                        .fill(resultColour.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .position(point(observation.center, in: size))
                }

                // Where it met the scoring plane.
                if let crossing = decidingCrossing, let rim = attempt.rim, crossingHasHappened {
                    let at = point(CGPoint(x: crossing.x, y: rim.scoringPlaneY), in: size)

                    Circle()
                        .stroke(resultColour, lineWidth: 2.5)
                        .frame(width: 16, height: 16)
                        .position(at)
                }
            }
        }
    }

    private var decidingCrossing: RimCrossing? {
        attempt.crossings.min(by: { abs($0.normalisedOffset) < abs($1.normalisedOffset) })
    }

    private var resultColour: Color {
        switch attempt.result {
        case .made: return .green
        case .missed: return .red
        case .abandoned: return .gray
        case .inProgress: return .yellow
        }
    }
}

/// One shot in the timeline: the frame it happened on, its path, and the verdict.
struct ShotCardView: View {
    let attempt: ShotAttempt
    let provider: ShotFrameProvider?

    @State private var frame: Image?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let frame {
                    frame
                        .resizable()
                        .scaledToFit()
                        .overlay { ShotTrajectoryOverlay(attempt: attempt) }
                } else {
                    // Hold the shape so rows don't jump as frames decode in.
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            } else {
                                Label("No frame", systemImage: "film.stack")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) { resultBadge.padding(8) }

            details
        }
        .padding(.vertical, 4)
        .task(id: attempt.id) {
            guard let provider else {
                isLoading = false
                return
            }
            frame = await provider.image(for: attempt)
            isLoading = false
        }
    }

    private var resultBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(attempt.result.rawValue.capitalized)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(colour)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let time = attempt.keyTime {
                    Label(timecode(time), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(frameRange)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                if let crossing = decidingCrossing {
                    // 0.0 is dead centre of the ring, 1.0 is the ring itself.
                    ShotTag(text: String(format: "offset %.2f", abs(crossing.normalisedOffset)))
                }
                if attempt.rimContacts > 0 {
                    ShotTag(text: "rim ×\(attempt.rimContacts)")
                }
                if attempt.wasDetectedLate {
                    ShotTag(text: "late pickup")
                }
                if attempt.isCloseCall {
                    ShotTag(text: "close call", tint: .orange)
                }
            }
        }
    }

    private var decidingCrossing: RimCrossing? {
        attempt.crossings.min(by: { abs($0.normalisedOffset) < abs($1.normalisedOffset) })
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d.%02d",
                      total / 60,
                      total % 60,
                      Int((seconds - Double(total)) * 100))
    }

    private var frameRange: String {
        guard let end = attempt.endFrame else { return "frame \(attempt.startFrame)–" }
        return "frames \(attempt.startFrame)–\(end)"
    }

    private var symbol: String {
        switch attempt.result {
        case .made: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .abandoned: return "questionmark.circle.fill"
        case .inProgress: return "circle.dotted"
        }
    }

    private var colour: Color {
        switch attempt.result {
        case .made: return .green
        case .missed: return .red
        case .abandoned: return .secondary
        case .inProgress: return .yellow
        }
    }
}

struct ShotTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
