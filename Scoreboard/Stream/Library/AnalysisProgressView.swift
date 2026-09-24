//
//  AnalysisProgressView.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import SwiftUI

/// The choice offered before a pass starts: watch it, or let it run.
///
/// Watching is the better default the first time through a clip — it is how you catch a
/// rim in the wrong place, or the ball going undetected — but it costs a decoded image
/// and a full redraw every frame. Once the setup is known to be right, none of that is
/// worth waiting for.
struct AnalysisStartCard: View {

    let clipDuration: Double
    let hasRim: Bool

    let onWatch: () -> Void
    let onRunWithoutWatching: () -> Void

    var body: some View {
        ZStack {
            // The frame behind can be anything from a dark gym to a bright outdoor
            // court, so the card gets its own backdrop rather than trusting the material
            // to carry the contrast.
            Color.black.opacity(0.5).ignoresSafeArea()

            card
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Ready to analyse")
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                choice(
                    title: "Watch the analysis",
                    detail: "Every frame on screen, with what the detector sees",
                    symbol: "eye",
                    isProminent: true,
                    action: onWatch
                )

                choice(
                    title: "Analyse without watching",
                    detail: "Skips drawing each frame, so it finishes sooner",
                    symbol: "eye.slash",
                    isProminent: false,
                    action: onRunWithoutWatching
                )
            }
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .padding(24)
    }

    private var subtitle: String {
        let length = clipDuration > 0 ? ShotScrubber.length(clipDuration) : "this clip"

        return hasRim
            ? "\(length) of footage, rim found. You can switch views at any time."
            : "\(length) of footage. No rim found yet — watching lets you place it."
    }

    private func choice(
        title: String,
        detail: String,
        symbol: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        // Without this the row hands the text a single line and it is
                        // truncated mid-sentence.
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isProminent ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

/// What replaces the video while a pass runs unwatched.
///
/// Deliberately not a bare spinner: with no frames to look at, the numbers are the only
/// evidence the run is working, and a shot tally that climbs says more about whether the
/// detector is doing its job than a percentage does.
struct AnalysisProgressStage: View {

    /// The last decoded frame, as a backdrop. Nothing is being drawn onto it any more.
    let poster: Image?

    let progress: AnalysisProgress
    let stats: ShotStats
    let shotsFound: Int
    let isRunning: Bool

    let onShowPreview: () -> Void

    var body: some View {
        ZStack {
            if let poster {
                poster
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .overlay(.black.opacity(0.65))
                    .clipped()
            } else {
                Color.black
            }

            VStack(spacing: 16) {
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)

                ProgressView(value: progress.fraction)
                    .tint(.white)
                    .frame(maxWidth: 260)

                VStack(spacing: 3) {
                    Text(positionLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))

                    if let remaining = progress.remainingDescription, isRunning {
                        Text(remaining)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    } else if !isRunning {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                tally

                Button(action: onShowPreview) {
                    Label("Show the video", systemImage: "eye")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    private var positionLine: String {
        let position = "\(ShotScrubber.timecode(progress.analysedSeconds)) of \(ShotScrubber.timecode(progress.clipSeconds))"

        guard let speed = progress.speed else { return position }
        return position + String(format: " · %.1f× real time", speed)
    }

    private var tally: some View {
        HStack(spacing: 18) {
            figure("\(shotsFound)", label: shotsFound == 1 ? "shot" : "shots")
            figure("\(stats.makes)/\(stats.attempts)", label: "made")
            figure(String(format: "%.0f%%", stats.fieldGoalPercentage), label: "FG")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func figure(_ value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
