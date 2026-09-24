//
//  ShotWindowScrubber.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import SwiftUI

/// A scrubber for one shot, spanning only that shot's window.
///
/// The clip-wide bar can't do this job. A padded shot window is about ten points wide on
/// a 90-second clip and three on a five-minute one, so positioning within a shot there is
/// a matter of luck — and the snap radius is wider than the whole window, so the
/// magnetism actively fights it.
///
/// Spread across the full width instead, the same window is about ten milliseconds per
/// point: frame-accurate by thumb. The two bars split the work rather than competing —
/// the clip-wide one finds the shot and snaps to it, this one moves around inside it and
/// never snaps to anything.
struct ShotWindowScrubber: View {

    let marker: ShotMarker
    let currentTime: Double

    /// Where this shot sits on the clip-wide bar below, 0–1, so the caret can point at
    /// it. Without the pointer the two bars are just two bars; with it, it is obvious
    /// which part of the clip this one has been opened on.
    let caretFraction: Double

    let onScrubBegan: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnded: () -> Void

    @State private var isDragging = false

    /// Matches `ShotScrubber`'s inset, so the caret lines up with the marker below it.
    private let inset: CGFloat = 10

    private var window: ClosedRange<Double> { marker.window }
    private var span: Double { max(window.upperBound - window.lowerBound, 0.01) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let midY = geometry.size.height / 2

                ZStack(alignment: .topLeading) {
                    track(width: width, midY: midY)

                    // The moment that decided the shot, so the rim crossing can be found
                    // without hunting for it.
                    keyTick
                        .position(x: x(for: marker.time, width: width), y: midY)

                    playhead
                        .position(x: x(for: currentTime, width: width), y: midY)
                }
                .frame(width: width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(drag(width: width))
            }
            .frame(height: 34)

            caret
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    // MARK: Pieces

    private func track(width: CGFloat, midY: CGFloat) -> some View {
        let height: CGFloat = isDragging ? 10 : 7
        let usable = max(width - inset * 2, 0)
        let played = max(0, x(for: currentTime, width: width) - inset)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(marker.tint.opacity(0.22))
                .frame(width: usable, height: height)
                .overlay(
                    Capsule()
                        .stroke(marker.tint.opacity(0.45), lineWidth: 1)
                        .frame(width: usable, height: height)
                )

            Capsule()
                .fill(marker.tint.opacity(0.75))
                .frame(width: played, height: height)
        }
        .offset(x: inset)
        .position(x: width / 2, y: midY)
        .frame(width: width)
    }

    private var keyTick: some View {
        Capsule()
            .fill(.white.opacity(0.9))
            .frame(width: 2, height: 16)
    }

    private var playhead: some View {
        Circle()
            .fill(.white)
            .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .overlay {
                if isDragging {
                    Text(offsetLabel)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .fixedSize()
                        .offset(y: -26)
                }
            }
    }

    /// Points down at this shot's position on the clip-wide bar underneath.
    private var caret: some View {
        GeometryReader { geometry in
            Triangle()
                .fill(marker.tint.opacity(0.65))
                .frame(width: 10, height: 5)
                .position(
                    x: inset + (CGFloat(min(max(caretFraction, 0), 1)) * max(geometry.size.width - inset * 2, 0)),
                    y: 3
                )
        }
        .frame(height: 6)
    }

    // MARK: Gesture

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onScrubBegan()
                }
                onScrub(time(atX: value.location.x, width: width))
            }
            .onEnded { value in
                onScrub(time(atX: value.location.x, width: width))
                isDragging = false
                onScrubEnded()
            }
    }

    // MARK: Geometry

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        let fraction = min(max((time - window.lowerBound) / span, 0), 1)
        return inset + (CGFloat(fraction) * max(width - inset * 2, 0))
    }

    /// Clamped to the window: this bar can only move within its shot, which is what keeps
    /// it precise. Leaving the shot is the clip-wide bar's job.
    private func time(atX location: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((location - inset) / usable, 0), 1)
        return window.lowerBound + (Double(fraction) * span)
    }

    /// Position relative to the rim crossing, which is more use than an absolute
    /// timecode here — "0.4s before it went in" is the thing being looked for.
    private var offsetLabel: String {
        let delta = currentTime - marker.time

        if abs(delta) < 0.05 { return "crossing" }
        return String(format: "%@%.2fs", delta < 0 ? "−" : "+", abs(delta))
    }
}

/// A downward-pointing triangle, for the caret.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
