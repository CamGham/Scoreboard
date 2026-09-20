//
//  AnalysisReviewView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI
import AVFoundation

/// Where analysis lands the user: the whole clip, playable, with every detected shot
/// marked on a colour-coded scrubber.
///
/// The shot timeline answers "what happened"; this answers "let me see it". The card list
/// is still the better tool for working through shots one at a time — it is a tap away in
/// the top bar — but it can't show a shot in the context of the clip around it, and it
/// can't show the gaps where nothing was detected at all.
struct AnalysisReviewView: View {

    let gameState: GameState
    let asset: AVAsset

    /// Natural size of the video *after* orientation, so the overlay matches the picture.
    let orientedVideoSize: CGSize

    let onDismiss: () -> Void

    /// Supplies the still frame each timeline card is drawn on.
    var frameProvider: ShotFrameProvider?

    var ballStats: BallDetectionStats?

    /// Stretches of the clip already flagged for another pass.
    var sections: [ReanalysisSection] = []

    /// Reports the new set whenever a section is marked or removed, so the caller can
    /// write it to disk. Nil leaves the bar read-only — a video whose marks can't be
    /// stored shouldn't offer to take them.
    var onSectionsChanged: (([ReanalysisSection]) -> Void)?

    @State private var player: AnalysisReviewPlayer?
    @State private var showsChrome = true
    @State private var showTimeline = false

    /// The section being marked. Non-nil is "marking mode": the bar edits this range
    /// instead of seeking, and the ruling bar gets out of the way.
    @State private var draftRange: ClosedRange<Double>?

    @State private var showSections = false

    private static let rates: [Float] = [0.25, 0.5, 1.0, 2.0]

    /// Frame step, in seconds. Fixed at 30fps rather than read from the track — a step
    /// only has to be small enough to land on the next frame of typical footage.
    private static let frameStep = 1.0 / 30.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoStage.ignoresSafeArea()

            // Chrome respects the safe area so the close button clears the notch and the
            // scrubber clears the home indicator; only the gradients bleed to the edges.
            VStack(spacing: 0) {
                if showsChrome { topBar }
                Spacer(minLength: 0)
                if showsChrome { controls }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .statusBarHidden()
        .onAppear {
            let review = AnalysisReviewPlayer(asset: asset)
            player = review
            // Open on the run-up to the first shot rather than at 0:00 — on a long clip
            // the opening seconds are usually somebody walking to the line.
            review.start(seekingTo: markers.first?.window.lowerBound)
        }
        .onDisappear {
            // Not optional — AVPlayer traps if it is deallocated with a time observer
            // still registered.
            player?.stop()
            player = nil
        }
        .sheet(isPresented: $showSections) {
            ReanalysisSectionsView(
                sections: sections,
                onJump: { section in
                    showSections = false
                    player?.jump(to: section.startTime)
                },
                onDelete: { section in
                    onSectionsChanged?(sections.filter { $0.id != section.id })
                },
                onDismiss: { showSections = false }
            )
        }
        .sheet(isPresented: $showTimeline) {
            ShotTimelineView(
                gameState: gameState,
                ballStats: ballStats,
                frameProvider: frameProvider,
                asset: asset,
                orientedVideoSize: orientedVideoSize
            )
        }
    }

    // MARK: Shots

    /// Every ruling the user makes recolours a marker, so this is derived on each pass
    /// rather than captured once.
    private var markers: [ShotMarker] {
        ShotMarker.markers(
            from: gameState.reviewableAttempts,
            duration: player?.duration ?? 0
        )
    }

    /// The shot the playhead is inside, if any. Overlapping windows are broken by
    /// whichever key moment is closest.
    private var activeMarker: ShotMarker? {
        guard let player else { return nil }
        let time = player.currentTime

        let containing = markers.filter { $0.window.contains(time) }
        guard !containing.isEmpty else { return nil }

        return containing.min { abs($0.time - time) < abs($1.time - time) }
    }

    private var activeAttempt: ShotAttempt? {
        guard let id = activeMarker?.id else { return nil }
        return gameState.attempt(withID: id)
    }

    // MARK: Stage

    @ViewBuilder
    private var videoStage: some View {
        if let player {
            GeometryReader { geometry in
                let content = VideoLayout.contentRect(
                    for: orientedVideoSize,
                    in: geometry.size
                )

                ZStack(alignment: .topLeading) {
                    PlayerLayerView(player: player.player)

                    // The overlay only appears while a shot is on screen. Drawing it the
                    // whole way through would leave a stale path hanging over footage it
                    // has nothing to do with.
                    if let attempt = activeAttempt {
                        ShotTrajectoryOverlay(attempt: attempt, upTo: player.currentTime)
                            .frame(width: content.width, height: content.height)
                            .offset(x: content.minX, y: content.minY)

                        if let position = interpolatedBallPosition(
                            trajectory: attempt.trajectory,
                            atTime: player.currentTime
                        ) {
                            Circle()
                                .stroke(.white, lineWidth: 2)
                                .frame(width: 22, height: 22)
                                .position(VideoLayout.point(normalized: position, in: content))
                        }
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

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            scoreline

            Spacer()

            Button {
                player?.pause()
                showTimeline = true
            } label: {
                Image(systemName: "list.clipboard")
                    .font(.footnote.weight(.bold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
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

    private var scoreline: some View {
        let stats = gameState.stats

        return HStack(spacing: 10) {
            VStack(spacing: -1) {
                Text("\(stats.makes)/\(stats.attempts)")
                    .font(.headline.monospacedDigit())
                Text("made")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 24).overlay(.white.opacity(0.25))

            VStack(spacing: -1) {
                Text(String(format: "%.0f%%", stats.fieldGoalPercentage))
                    .font(.headline.monospacedDigit())
                Text("FG")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if let player {
            VStack(spacing: 8) {
                shotReadout(player)

                ShotScrubber(
                    duration: player.duration,
                    currentTime: player.currentTime,
                    markers: markers,
                    activeMarkerID: activeMarker?.id,
                    markedSections: sections.map(\.range),
                    editingRange: draftRange,
                    onEditRange: { range, edge in
                        draftRange = range
                        // Follow the end being dragged, so the frame on screen is the one
                        // the section will start or stop at.
                        player.scrub(to: edge == .start ? range.lowerBound : range.upperBound)
                    },
                    onScrubBegan: { player.beginScrubbing() },
                    onScrub: { player.scrub(to: $0) },
                    onScrubEnded: { player.endScrubbing() }
                )

                transport(player)

                if onSectionsChanged != nil {
                    sectionBar(player)
                }

                // One job at a time: while marking, the ruling buttons would be a second
                // set of commitments competing for the same corner of the screen.
                if let attempt = activeAttempt, draftRange == nil {
                    ShotVerdictBar(attempt: attempt) { verdict in
                        gameState.setVerdict(verdict, for: attempt.id)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeMarker?.id)
            .animation(.easeInOut(duration: 0.2), value: draftRange)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    /// The line above the bar: which shot you are on, or how many there are to find.
    private func shotReadout(_ player: AnalysisReviewPlayer) -> some View {
        HStack(spacing: 8) {
            if draftRange != nil {
                Image(systemName: "scissors")
                    .foregroundStyle(.blue)
                Text("Drag the handles to set the section")
                    .foregroundStyle(.white)
            } else if let marker = activeMarker {
                Image(systemName: marker.symbol)
                    .foregroundStyle(marker.tint)

                Text("Shot \(marker.ordinal) of \(markers.count) · \(marker.label)")
                    .foregroundStyle(.white)

                if marker.isCorrected {
                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                }
                if marker.isCloseCall {
                    ShotTag(text: "close call", tint: .orange)
                }
            } else if markers.isEmpty {
                Text("No shots detected in this clip")
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                legend
            }

            Spacer()

            Text("\(ShotScrubber.timecode(player.currentTime)) / \(ShotScrubber.timecode(player.duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption.weight(.semibold))
        .frame(height: 20)
    }

    /// Shown between shots, so the colours on the bar explain themselves without a tap.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(legendEntries, id: \.label) { entry in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(entry.tint)
                        .frame(width: 3, height: 10)
                    Text("\(entry.count) \(entry.label)")
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .font(.caption2.weight(.medium))
    }

    private var legendEntries: [(label: String, tint: Color, count: Int)] {
        let made = markers.filter { $0.result == .made && !$0.isNotAShot }.count
        let missed = markers.filter { $0.result == .missed && !$0.isNotAShot }.count
        let unresolved = markers.count - made - missed

        var entries: [(String, Color, Int)] = [("made", .green, made), ("missed", .red, missed)]
        if unresolved > 0 { entries.append(("unresolved", .orange, unresolved)) }

        return entries.map { (label: $0.0, tint: $0.1, count: $0.2) }
    }

    private func transport(_ player: AnalysisReviewPlayer) -> some View {
        HStack(spacing: 4) {
            // Shot-to-shot first: on a clip with a dozen attempts, these and the bar are
            // what actually get used.
            transportButton("backward.end.fill", disabled: previousMarker(from: player.currentTime) == nil) {
                jump(to: previousMarker(from: player.currentTime), player: player)
            }

            transportButton("backward.frame.fill") {
                player.step(by: -Self.frameStep)
            }

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .frame(width: 54, height: 44)
            }
            .contentTransition(.symbolEffect(.replace))

            transportButton("forward.frame.fill") {
                player.step(by: Self.frameStep)
            }

            transportButton("forward.end.fill", disabled: nextMarker(from: player.currentTime) == nil) {
                jump(to: nextMarker(from: player.currentTime), player: player)
            }

            Spacer(minLength: 0)

            rateButton(player)
        }
        .font(.title3)
        .foregroundStyle(.white)
    }

    private func transportButton(
        _ symbol: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                // A fixed hit area, so a 14pt glyph is still a 44pt target.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    /// A menu rather than a segmented control: four segments would eat half the row, and
    /// the rate is changed far less often than the transport is touched.
    private func rateButton(_ player: AnalysisReviewPlayer) -> some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { player.rate },
                set: { player.rate = $0 }
            )) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.rateLabel(player.rate))
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 32)
                .background(.white.opacity(0.16), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }

    // MARK: Marking a section

    /// The row under the transport: start a mark, or commit the one in progress.
    @ViewBuilder
    private func sectionBar(_ player: AnalysisReviewPlayer) -> some View {
        if let draftRange {
            HStack(spacing: 8) {
                Text("\(ShotScrubber.timecode(draftRange.lowerBound))–\(ShotScrubber.timecode(draftRange.upperBound))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)

                Text(ShotScrubber.length(draftRange.upperBound - draftRange.lowerBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))

                Spacer(minLength: 8)

                chip("Cancel", tint: .white.opacity(0.14)) { self.draftRange = nil }

                chip("Mark for re-analysis", systemImage: "checkmark", tint: .blue) {
                    save(draftRange, clipDuration: player.duration)
                }
            }
        } else {
            HStack(spacing: 10) {
                chip("Mark section", systemImage: "scissors", tint: .white.opacity(0.14)) {
                    beginMarking(player)
                }

                Spacer(minLength: 8)

                if !sections.isEmpty {
                    chip(
                        "\(sections.count) marked · \(ShotScrubber.length(markedDuration))",
                        systemImage: "rectangle.stack",
                        tint: .blue.opacity(0.35)
                    ) {
                        player.pause()
                        showSections = true
                    }
                }
            }
        }
    }

    private func chip(
        _ title: String,
        systemImage: String? = nil,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// Open a section around the current frame — or reopen the one it is already inside,
    /// since extending a mark is far more likely than stacking a second on top of it.
    private func beginMarking(_ player: AnalysisReviewPlayer) {
        player.pause()

        let time = player.currentTime

        if let existing = sections.first(where: { $0.range.contains(time) }) {
            draftRange = existing.range
        } else {
            draftRange = ReanalysisSection.normalised(
                (time - Self.defaultSectionPadding)...(time + Self.defaultSectionPadding),
                clipDuration: player.duration
            )
        }
    }

    private func save(_ range: ClosedRange<Double>, clipDuration: Double) {
        onSectionsChanged?(sections.marking(range, clipDuration: clipDuration))
        draftRange = nil
    }

    /// Half the length of a freshly opened section. Roughly a shot's run-up either side
    /// of the frame you stopped on, which is usually about the right place to start.
    private static let defaultSectionPadding: Double = 2

    private var markedDuration: Double {
        sections.reduce(0) { $0 + $1.duration }
    }

    // MARK: Shot navigation

    /// Land on the run-up rather than the rim crossing — a shot makes no sense from
    /// halfway through its arc.
    private func jump(to marker: ShotMarker?, player: AnalysisReviewPlayer) {
        guard let marker else { return }
        player.jump(to: marker.window.lowerBound)
    }

    private func nextMarker(from time: Double) -> ShotMarker? {
        // Measured against the window, so "next" doesn't mean the shot already playing.
        markers.first { $0.window.lowerBound > time + 0.05 }
    }

    private func previousMarker(from time: Double) -> ShotMarker? {
        markers.last { $0.window.lowerBound < time - 0.05 }
    }
}

/// Made / missed / not-a-shot, for the shot currently on screen.
///
/// Placed with the transport because this is the moment the user actually knows the
/// answer — they have just watched it.
struct ShotVerdictBar: View {

    let attempt: ShotAttempt
    let onVerdict: (ShotAttempt.UserVerdict?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ShotAttempt.UserVerdict.allCases, id: \.self) { verdict in
                let isActive = attempt.userVerdict == verdict

                Button {
                    // Tapping the active ruling clears it, handing the shot back to the
                    // detector's call.
                    onVerdict(isActive ? nil : verdict)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: verdict.symbol)
                        Text(verdict.label)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        isActive ? tint(verdict).opacity(0.85) : Color.white.opacity(0.14),
                        in: Capsule()
                    )
                    .foregroundStyle(isActive ? .black : .white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tint(_ verdict: ShotAttempt.UserVerdict) -> Color {
        switch verdict {
        case .made: return .green
        case .missed: return .red
        case .notAShot: return .orange
        }
    }
}
