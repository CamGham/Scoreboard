//
//  ShotScrubber.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI
import UIKit

/// One detected shot, reduced to what a scrubber needs to draw and snap to it.
///
/// Deliberately not a `ShotAttempt`: the scrubber shouldn't care about trajectories or
/// rim geometry, and keeping it to times and a colour makes the control previewable
/// without an analysis pass behind it.
struct ShotMarker: Identifiable, Equatable {

    let id: UUID

    /// 1-based position in the clip, so the UI can say "shot 4 of 12".
    let ordinal: Int

    /// The moment worth landing on — the rim crossing where there was one.
    let time: Double

    /// Padded bounds of the attempt, so a jump starts at the run-up rather than mid-air.
    let window: ClosedRange<Double>

    let result: ShotAttempt.Result
    let isNotAShot: Bool
    let isCorrected: Bool
    let isCloseCall: Bool

    /// The colour code. This is the whole point of the control: a glance at the bar
    /// should say how the session went before a single frame is played.
    var tint: Color {
        if isNotAShot { return .gray }
        switch result {
        case .made: return .green
        case .missed: return .red
        case .abandoned: return .orange
        case .inProgress: return .yellow
        }
    }

    var label: String {
        if isNotAShot { return "Not a shot" }
        switch result {
        case .made: return "Made"
        case .missed: return "Missed"
        case .abandoned: return "Unresolved"
        case .inProgress: return "In flight"
        }
    }

    var symbol: String {
        if isNotAShot { return "nosign" }
        switch result {
        case .made: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .abandoned: return "questionmark.circle.fill"
        case .inProgress: return "circle.dotted"
        }
    }

    /// The marker a scrub landing at `time` should snap onto, if any.
    ///
    /// Pulled out of the gesture so the magnetism can be reasoned about — and tested —
    /// without a drag. `radius` is in seconds; the control converts its on-screen snap
    /// distance into seconds for the clip it is showing.
    static func snapTarget(
        for time: Double,
        in markers: [ShotMarker],
        within radius: Double
    ) -> ShotMarker? {
        guard radius > 0 else { return nil }

        let nearest = markers.min { abs($0.time - time) < abs($1.time - time) }
        guard let nearest, abs(nearest.time - time) <= radius else { return nil }

        return nearest
    }

    /// Build the marker set for a clip, in time order.
    ///
    /// Attempts with no key time are dropped rather than pinned to zero — those come from
    /// footage where no presentation time could be read, and a marker at the start of the
    /// clip would be a lie rather than an approximation.
    static func markers(
        from attempts: [ShotAttempt],
        duration: Double,
        padding: Double = 0.75
    ) -> [ShotMarker] {

        let timed = attempts
            .compactMap { attempt -> (ShotAttempt, Double)? in
                guard let key = attempt.keyTime, key.isFinite else { return nil }
                return (attempt, key)
            }
            .sorted { $0.1 < $1.1 }

        return timed.enumerated().map { index, entry in
            let (attempt, key) = entry
            let upperLimit = duration > 0 ? duration : key + padding

            let start = max(0, (attempt.startTime ?? key) - padding)
            let end = min(upperLimit, max(start + 0.1, (attempt.endTime ?? key) + padding))

            return ShotMarker(
                id: attempt.id,
                ordinal: index + 1,
                time: min(max(key, 0), upperLimit),
                window: start...max(start + 0.1, end),
                result: attempt.effectiveResult,
                isNotAShot: attempt.userVerdict == .notAShot,
                isCorrected: attempt.isCorrected,
                isCloseCall: attempt.isCloseCall
            )
        }
    }
}

/// A timeline bar for a whole clip, with every detected shot marked and colour coded.
///
/// The bar is magnetic: a drag that passes within a few points of a marker snaps onto it
/// exactly, with a haptic tick. Shots last under a second, so on a several-minute clip a
/// shot occupies well under a pixel of travel — without snapping, landing on one by hand
/// is a matter of luck, which is what makes a plain `Slider` useless here.
struct ShotScrubber: View {

    let duration: Double
    let currentTime: Double
    let markers: [ShotMarker]

    /// The shot the playhead is currently inside, drawn larger so it is obvious which
    /// one is on screen.
    var activeMarkerID: UUID?

    let onScrubBegan: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnded: () -> Void

    @State private var isDragging = false
    @State private var snappedMarkerID: UUID?
    @State private var haptics = UIImpactFeedbackGenerator(style: .light)

    /// Half a playhead's width, kept clear at each end so the knob and the first and last
    /// markers stay fully on screen.
    private let inset: CGFloat = 10

    private let barHeight: CGFloat = 56

    /// How close a finger has to come to a marker before it snaps, in points.
    private let snapRadius: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let midY = geometry.size.height / 2

            ZStack(alignment: .topLeading) {
                track(width: width, midY: midY)

                ForEach(markers) { marker in
                    tick(for: marker)
                        .position(x: x(for: marker.time, width: width), y: midY)
                }

                playhead
                    .position(x: x(for: currentTime, width: width), y: midY)

                if isDragging {
                    bubble
                        .position(
                            x: bubbleX(width: width),
                            y: max(14, midY - 30)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: width, height: geometry.size.height)
            // The whole strip is the target, not just the thin bar — a 6pt tall track is
            // not something a thumb can be expected to find.
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: barHeight)
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .animation(.easeOut(duration: 0.15), value: activeMarkerID)
    }

    // MARK: Pieces

    private func track(width: CGFloat, midY: CGFloat) -> some View {
        let height: CGFloat = isDragging ? 9 : 6
        let played = max(0, x(for: currentTime, width: width) - inset)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: max(width - inset * 2, 0), height: height)

            // Everything watched so far, plus a hint of the shot colours it passed.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0.65)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: played, height: height)
        }
        .offset(x: inset)
        .position(x: width / 2, y: midY)
        .frame(width: width)
    }

    private func tick(for marker: ShotMarker) -> some View {
        let isActive = marker.id == activeMarkerID || marker.id == snappedMarkerID
        let height: CGFloat = isActive ? 30 : 20
        let width: CGFloat = isActive ? 5 : 3.5

        return ZStack {
            // A dark backing so a green tick still reads against a pale played track.
            Capsule()
                .fill(.black.opacity(0.45))
                .frame(width: width + 2.5, height: height + 2.5)

            Capsule()
                .fill(marker.tint)
                .frame(width: width, height: height)

            // Close calls are the ones worth a second look, so they are flagged on the
            // bar itself rather than only once you have opened the shot.
            if marker.isCloseCall {
                Capsule()
                    .stroke(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: width, height: height)
            }
        }
        .shadow(color: marker.tint.opacity(isActive ? 0.8 : 0), radius: 5)
    }

    private var playhead: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: isDragging ? 20 : 15, height: isDragging ? 20 : 15)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)

            if let snapped = snappedMarker {
                Circle()
                    .fill(snapped.tint)
                    .frame(width: 8, height: 8)
            }
        }
    }

    /// Floating readout while dragging: where you are, and what you are on top of.
    private var bubble: some View {
        HStack(spacing: 5) {
            if let snapped = snappedMarker {
                Image(systemName: snapped.symbol)
                    .foregroundStyle(snapped.tint)
                Text("Shot \(snapped.ordinal)")
                    .foregroundStyle(.white)
            }
            Text(Self.timecode(currentTime))
                .foregroundStyle(snappedMarker == nil ? .white : .white.opacity(0.7))
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .fixedSize()
    }

    // MARK: Gesture

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    haptics.prepare()
                    onScrubBegan()
                }
                commit(x: value.location.x, width: width)
            }
            .onEnded { value in
                commit(x: value.location.x, width: width)
                isDragging = false
                snappedMarkerID = nil
                onScrubEnded()
            }
    }

    /// Turn a finger position into a time, snapping onto a nearby marker.
    private func commit(x location: CGFloat, width: CGFloat) {
        guard duration > 0 else { return }

        let raw = time(atX: location, width: width)
        let usable = max(width - inset * 2, 1)

        // Convert the snap radius into seconds for this bar width, so the magnetism is a
        // constant distance on screen no matter how long the clip is.
        let radius = (Double(snapRadius) / Double(usable)) * duration

        if let target = ShotMarker.snapTarget(for: raw, in: markers, within: radius) {
            if snappedMarkerID != target.id {
                snappedMarkerID = target.id
                haptics.impactOccurred(intensity: 0.7)
            }
            onScrub(target.time)
        } else {
            snappedMarkerID = nil
            onScrub(raw)
        }
    }

    // MARK: Geometry

    private var snappedMarker: ShotMarker? {
        markers.first { $0.id == snappedMarkerID }
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return inset }
        let fraction = min(max(time / duration, 0), 1)
        return inset + (CGFloat(fraction) * max(width - inset * 2, 0))
    }

    private func time(atX location: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((location - inset) / usable, 0), 1)
        return Double(fraction) * duration
    }

    /// Keep the readout on screen when the playhead is near either end.
    private func bubbleX(width: CGFloat) -> CGFloat {
        min(max(x(for: currentTime, width: width), 58), max(width - 58, 58))
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Standalone harness for the scrubber, so the control can be tuned without running an
/// analysis pass to produce shots for it.
struct ShotScrubberDemo: View {

    @State private var currentTime: Double = 12

    private let duration: Double = 240

    private var markers: [ShotMarker] {
        let sample: [(Double, ShotAttempt.Result, Bool)] = [
            (14, .made, false), (31, .missed, false), (46, .made, true),
            (63, .missed, false), (69, .abandoned, false), (95, .made, false),
            (120, .made, false), (127, .missed, true), (168, .made, false),
            (171, .missed, false), (205, .made, false), (232, .abandoned, false)
        ]

        return sample.enumerated().map { index, entry in
            let (time, result, closeCall) = entry
            return ShotMarker(
                id: UUID(),
                ordinal: index + 1,
                time: time,
                window: (time - 1.2)...(time + 1.2),
                result: result,
                isNotAShot: false,
                isCorrected: false,
                isCloseCall: closeCall
            )
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 8) {
                Spacer()

                Text(ShotScrubber.timecode(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)

                ShotScrubber(
                    duration: duration,
                    currentTime: currentTime,
                    markers: markers,
                    activeMarkerID: markers.first { $0.window.contains(currentTime) }?.id,
                    onScrubBegan: {},
                    onScrub: { currentTime = $0 },
                    onScrubEnded: {}
                )
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
    }
}

#Preview {
    ShotScrubberDemo()
}
