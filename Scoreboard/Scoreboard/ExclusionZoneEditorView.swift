//
//  ExclusionZoneEditorView.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import SwiftUI

/// Draw the parts of the frame the ball can't be in.
///
/// Built on the same footing as `RimPlacementView`, deliberately: the thing being blocked
/// out is usually small and far away — a bin at the edge of the court, a sign on the far
/// wall — so zooming in to draw around it accurately matters just as much as it does for
/// a rim, and the two editors behaving differently would be its own bug.
///
/// A still is enough to work on because the things being blocked out don't move — see the
/// fixed-camera assumption on `ExclusionZone`.
struct ExclusionZoneEditorView: View {

    /// What a drag currently does. Zooming and drawing want the same gesture, so the user
    /// picks which one is live rather than the view guessing from finger count.
    enum Mode: String, CaseIterable {
        case navigate = "Zoom & Pan"
        case block = "Block Out"

        var symbol: String {
            switch self {
            case .navigate: return "arrow.up.left.and.down.right.magnifyingglass"
            case .block: return "nosign"
            }
        }
    }

    /// The frame to draw against — whatever moment the user was looking at.
    let backdrop: Image

    let initialZones: [ExclusionZone]

    let onCancel: () -> Void
    let onConfirm: ([ExclusionZone]) -> Void

    /// Opens ready to draw, unlike the rim editor.
    ///
    /// At 1× a drag in navigate mode is clamped to no movement at all, so opening in it
    /// would mean the first thing anyone tries — dragging a box — appears to do nothing.
    /// Drawing is also the reason to be here; zooming is in service of it.
    @State private var mode: Mode = .block

    /// Zones being edited, in normalized image space (origin top-left) so they survive
    /// zoom, pan and layout. Converted to Vision space only on confirm.
    @State private var boxes: [Editable] = []
    @State private var selection: UUID?

    // Zoom / pan. The `committed` values are what the last gesture settled on.
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    /// Box being dragged out for the first time, in image-space points.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    /// What the in-progress drag is doing, and the state it started from.
    @State private var activeGrab: RimBoxEditor.Grab?
    @State private var grabOriginBox: CGRect?
    @State private var grabOriginOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 12

    /// A zone while it is being edited: identity plus a rect in normalized image space.
    private struct Editable: Identifiable, Equatable {
        let id: UUID
        var rect: CGRect
        var createdAt: Date
    }

    var body: some View {
        NavigationStack {
            GeometryReader { container in
                ZStack {
                    Color.black

                    zoomableContent
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipped()
                }
                .frame(width: container.size.width, height: container.size.height)
                .contentShape(Rectangle())
                // Panning is measured in screen space, so it lives on the container,
                // outside the transform. In block mode the inner surface takes the drag
                // first and this never fires.
                .gesture(panGesture(container: container.size))
                // Pinch stays live in both modes: a two-finger pinch can't be confused
                // with drawing a box.
                .simultaneousGesture(magnifyGesture(container: container.size))
                .onTapGesture(count: 2) { resetZoom() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Blocked areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onConfirm(confirmedZones()) }
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: seedFromExistingZones)
        }
    }

    // MARK: Content

    private var zoomableContent: some View {
        backdrop
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { image in
                    ZStack {
                        zoneOverlay(size: image.size)

                        // A filling, hit-testable surface — without one the gesture has
                        // nothing to land on, and only while blocking, so navigate mode
                        // falls through to the container's pan.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(blockingGesture(size: image.size))
                            .allowsHitTesting(mode == .block)
                    }
                }
            }
    }

    @ViewBuilder
    private func zoneOverlay(size: CGSize) -> some View {
        // Hairlines divided by scale, so they stay thin on screen as you zoom in.
        let line = 2 / scale

        ZStack {
            ForEach(boxes) { zone in
                let box = zone.rect.denormalized(in: size)
                let isSelected = zone.id == selection

                Rectangle()
                    .fill(Color.red.opacity(isSelected ? 0.28 : 0.18))
                    .overlay(
                        Rectangle().stroke(
                            Color.red.opacity(isSelected ? 1 : 0.7),
                            style: StrokeStyle(
                                lineWidth: isSelected ? line * 1.5 : line,
                                dash: [6 / scale, 4 / scale]
                            )
                        )
                    )
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }

            // The box being dragged out right now.
            if let start = dragStart, let current = dragCurrent {
                let box = CGRect(from: start, to: current)

                Rectangle()
                    .fill(Color.red.opacity(0.2))
                    .overlay(
                        Rectangle().stroke(
                            Color.red,
                            style: StrokeStyle(lineWidth: line, dash: [6 / scale, 4 / scale])
                        )
                    )
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }

            // Handles on the selected zone, once nothing is being drawn.
            if mode == .block, dragStart == nil,
               let selection, let zone = boxes.first(where: { $0.id == selection }) {

                let box = zone.rect.denormalized(in: size)

                ForEach(RimBoxEditor.Handle.allCases, id: \.self) { handle in
                    let anchor = handle.point(in: box)
                    let isActive = activeGrab == .resize(handle)

                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Color.red, lineWidth: line))
                        // Sized in image space so it stays constant on screen at any zoom.
                        .frame(width: handleDiameter, height: handleDiameter)
                        .scaleEffect(isActive ? 1.4 : 1)
                        .position(x: anchor.x, y: anchor.y)
                }
            }
        }
    }

    private var handleDiameter: CGFloat { 18 / scale }
    private var handleHitRadius: CGFloat { 24 / scale }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Button {
                    resetZoom()
                } label: {
                    Label("\(scale, specifier: "%.1f")×", systemImage: "arrow.counterclockwise")
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.bordered)
                .disabled(scale == 1 && offset == .zero)

                Button("Delete", systemImage: "trash", role: .destructive) {
                    boxes.removeAll { $0.id == selection }
                    selection = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(selection == nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var hint: String {
        switch mode {
        case .navigate:
            return scale > 1.05
                ? "Drag to pan · pinch to zoom · switch to Block Out"
                : "Pinch to zoom in on whatever is being mistaken for the ball"
        case .block:
            return boxes.isEmpty
                ? "Drag a box over anything round or orange that isn't the ball"
                : "Drag inside a box to move · drag a bubble to resize · drag empty space for another"
        }
    }

    // MARK: Gestures

    private func blockingGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Classify once, on the first change, then stay committed to it — a grab
                // re-evaluated every frame would jump between move and resize as the
                // finger crossed a handle.
                if activeGrab == nil {
                    let rects = boxes.map { $0.rect.denormalized(in: size) }

                    // A drag starting on a zone edits that zone; anywhere else draws a
                    // new one, which is why an empty frame is immediately drawable.
                    if let hit = ExclusionZoneEditor.index(
                        at: value.startLocation,
                        in: rects,
                        slop: handleHitRadius
                    ) {
                        selection = boxes[hit].id
                        grabOriginBox = rects[hit]
                        activeGrab = RimBoxEditor.classify(
                            point: value.startLocation,
                            box: rects[hit],
                            hitRadius: handleHitRadius
                        )
                    } else {
                        selection = nil
                        grabOriginBox = nil
                        activeGrab = .draw
                    }

                    grabOriginOffset = offset
                }

                switch activeGrab {
                case .draw:
                    if dragStart == nil { dragStart = value.startLocation }
                    dragCurrent = value.location

                case .pan:
                    // Nothing grabbed, so the drag pans instead of editing. The
                    // translation arrives in unscaled image space, so it has to be
                    // scaled back up to the screen-space offset.
                    offset = clampOffset(
                        CGSize(
                            width: grabOriginOffset.width + (value.translation.width * scale),
                            height: grabOriginOffset.height + (value.translation.height * scale)
                        ),
                        container: size
                    )

                case .move, .resize:
                    guard let origin = grabOriginBox,
                          let selection,
                          let index = boxes.firstIndex(where: { $0.id == selection })
                    else { return }

                    let edited = RimBoxEditor.apply(
                        grab: activeGrab!,
                        origin: origin,
                        translation: value.translation,
                        bounds: size,
                        minimumSide: minimumSide(in: size)
                    )

                    boxes[index].rect = edited.normalized(in: size)

                case .none:
                    break
                }
            }
            .onEnded { value in
                if activeGrab == .draw {
                    let box = CGRect(from: value.startLocation, to: value.location)

                    // A tap is not a zone: too small and the drag is treated as a miss
                    // rather than grown into a box the user didn't draw.
                    if ExclusionZoneEditor.isBigEnough(box, minimumSide: minimumSide(in: size)),
                       size.width > 0, size.height > 0 {

                        let zone = Editable(
                            id: UUID(),
                            rect: RimBoxEditor.containing(box, in: size).normalized(in: size),
                            createdAt: Date()
                        )

                        boxes.append(zone)
                        selection = zone.id
                    }
                }

                if activeGrab == .pan {
                    committedOffset = offset
                }

                dragStart = nil
                dragCurrent = nil
                activeGrab = nil
                grabOriginBox = nil
            }
    }

    /// Smallest edge a zone may have, in image space. Against the image rather than the
    /// screen, so a small zone drawn at high zoom isn't rejected.
    private func minimumSide(in size: CGSize) -> CGFloat {
        size.width * Double(ExclusionZone.minimumSide) * 0.5
    }

    private func panGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampOffset(
                    CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    container: container
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, minScale), maxScale)
                offset = clampOffset(offset, container: container)
            }
            .onEnded { _ in
                committedScale = scale
                committedOffset = offset
            }
    }

    /// Keep the scaled content covering the container, so it can't be dragged away into
    /// empty space.
    private func clampOffset(_ proposed: CGSize, container: CGSize) -> CGSize {
        let maxX = max((container.width * (scale - 1)) / 2, 0)
        let maxY = max((container.height * (scale - 1)) / 2, 0)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            committedScale = 1
            offset = .zero
            committedOffset = .zero
        }
    }

    // MARK: Spaces

    private func seedFromExistingZones() {
        guard boxes.isEmpty else { return }

        boxes = initialZones.map {
            Editable(
                id: $0.id,
                rect: ExclusionZoneEditor.imageRect(fromVision: $0.rect),
                createdAt: $0.createdAt
            )
        }
    }

    private func confirmedZones() -> [ExclusionZone] {
        boxes.map {
            ExclusionZone(
                id: $0.id,
                rect: ExclusionZone.normalised(
                    ExclusionZoneEditor.visionRect(fromImage: $0.rect)
                ),
                createdAt: $0.createdAt
            )
        }
    }
}

private extension CGRect {
    /// Build from two drag points in any order.
    init(from: CGPoint, to: CGPoint) {
        self.init(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )
    }

    func normalized(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }

        return CGRect(
            x: minX / size.width,
            y: minY / size.height,
            width: width / size.width,
            height: height / size.height
        )
    }

    func denormalized(in size: CGSize) -> CGRect {
        CGRect(
            x: minX * size.width,
            y: minY * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

/// `Image` isn't `Identifiable`, and a sheet driven by the loaded still needs it to be.
struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: Image
}
