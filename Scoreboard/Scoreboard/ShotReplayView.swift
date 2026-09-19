//
//  ShotReplayView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI
import AVFoundation

/// Hosts an `AVPlayerLayer`. `VideoPlayer` brings its own controls and its own idea of
/// layout, neither of which suits an overlay that has to line up to the pixel.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Replays one shot on a loop with its recorded path drawn over it.
struct ShotReplayView: View {

    let attempt: ShotAttempt
    let asset: AVAsset

    /// Natural size of the video *after* orientation, so the overlay matches the picture.
    let orientedVideoSize: CGSize

    let onDismiss: () -> Void

    @State private var replay: ShotReplayPlayer?

    /// Controls are overlaid, so they can be dismissed to get a clear look at the shot.
    @State private var showsChrome = true

    private static let rates: [Float] = [0.1, 0.25, 0.5, 1.0]

    var body: some View {
        ZStack {
            // No aspect-ratio constraint on the stage: it fills whatever space there is
            // and letterboxes internally, so the picture is as large as it can be.
            Color.black
                .ignoresSafeArea()

            videoStage
                .ignoresSafeArea()

            // Chrome sits in its own layer that *respects* the safe area, so the close
            // button clears the notch and the scrubber clears the home indicator. Only
            // the gradients behind them bleed to the edges.
            VStack(spacing: 0) {
                if showsChrome { topBar }
                Spacer(minLength: 0)
                if showsChrome { controls }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .statusBarHidden()
        .onAppear {
            let player = ShotReplayPlayer(asset: asset, attempt: attempt)
            replay = player
            player.start()
        }
        .onDisappear {
            // Removing the time observer here is not optional — AVPlayer traps if it is
            // deallocated while one is still registered.
            replay?.stop()
            replay = nil
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                resultBadge
                summary
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var resultBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: resultSymbol)
            Text(attempt.result.rawValue.capitalized)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(resultColour)
    }

    private var resultSymbol: String {
        switch attempt.result {
        case .made: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .abandoned: return "questionmark.circle.fill"
        case .inProgress: return "circle.dotted"
        }
    }

    private var resultColour: Color {
        switch attempt.result {
        case .made: return .green
        case .missed: return .red
        case .abandoned: return .secondary
        case .inProgress: return .yellow
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var videoStage: some View {
        if let replay {
            GeometryReader { geometry in
                let content = VideoLayout.contentRect(
                    for: orientedVideoSize,
                    in: geometry.size
                )

                ZStack(alignment: .topLeading) {
                    PlayerLayerView(player: replay.player)

                    ShotTrajectoryOverlay(attempt: attempt, upTo: replay.currentTime)
                        .frame(width: content.width, height: content.height)
                        .offset(x: content.minX, y: content.minY)

                    // Live ball marker, interpolated so it tracks the picture smoothly
                    // instead of hopping between sightings.
                    if let position = interpolatedBallPosition(
                        trajectory: attempt.trajectory,
                        atTime: replay.currentTime
                    ) {
                        let at = VideoLayout.point(normalized: position, in: content)
                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 22, height: 22)
                            .position(at)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .onTapGesture { showsChrome.toggle() }
        } else {
            Color.black.overlay { ProgressView().tint(.white) }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if let replay {
            VStack(spacing: 10) {
                scrubber(replay)

                HStack {
                    transport(replay)
                    Spacer(minLength: 16)
                    ratePicker(replay)
                        .frame(maxWidth: 190)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private func scrubber(_ replay: ShotReplayPlayer) -> some View {
        HStack(spacing: 10) {
            Text(timecode(replay.currentTime))

            Slider(
                value: Binding(
                    get: { replay.progress },
                    set: { replay.scrub(toProgress: $0) }
                ),
                in: 0...1
            ) { editing in
                // Pausing isn't enough on its own: the player has to be told a scrub is
                // in progress so its ticks stop writing over the finger's position.
                if editing {
                    replay.beginScrubbing()
                } else {
                    replay.endScrubbing()
                }
            }

            Text(timecode(replay.window.upperBound))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
    }

    private func transport(_ replay: ShotReplayPlayer) -> some View {
        HStack(spacing: 20) {
            Button {
                replay.step(by: -1.0 / 30.0)
            } label: {
                Image(systemName: "backward.frame.fill")
            }

            Button {
                replay.togglePlayback()
            } label: {
                Image(systemName: replay.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .contentTransition(.symbolEffect(.replace))

            Button {
                replay.step(by: 1.0 / 30.0)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
    }

    private func ratePicker(_ replay: ShotReplayPlayer) -> some View {
        Picker("Speed", selection: Binding(
            get: { replay.rate },
            set: { replay.rate = $0 }
        )) {
            ForEach(Self.rates, id: \.self) { rate in
                Text(rate == 1.0 ? "1×" : "\(rate, specifier: "%g")×").tag(rate)
            }
        }
        .pickerStyle(.segmented)
    }

    private var summary: some View {
        HStack(spacing: 6) {
            if let crossing = attempt.crossings.min(by: {
                abs($0.normalisedOffset) < abs($1.normalisedOffset)
            }) {
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

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let total = Int(seconds)
        return String(format: "%d:%02d.%02d",
                      total / 60,
                      total % 60,
                      Int((seconds - Double(total)) * 100))
    }
}
