//
//  RimPlacementView.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import SwiftUI

/// Lets the user position the rim by hand when the detector can't find it.
///
/// A single tap would only give a centre, but the make/miss verdict measures the
/// crossing offset in units of the rim's horizontal radius — so getting the *width*
/// wrong skews every call. Dragging a box captures both radii in one gesture, and the
/// ellipse and scoring plane are drawn live so the placement can be checked against the
/// rim in the frame underneath.
///
/// A rim occupies a very small part of a wide court frame, so the view zooms and pans.
/// Crucially the placement gesture lives *inside* the transformed content, which means
/// its coordinates stay in unscaled image space: at 4× a 40pt finger movement becomes a
/// 10pt movement in image space, so zooming buys real precision rather than just a
/// bigger picture.
struct RimPlacementView: View {

    /// What a drag currently does. Zooming and placing want the same gesture, so the
    /// user picks which one is live rather than the view guessing from finger count.
    enum Mode: String, CaseIterable {
        case navigate = "Zoom & Pan"
        case place = "Place Rim"

        var symbol: String {
            switch self {
            case .navigate: return "arrow.up.left.and.down.right.magnifyingglass"
            case .place: return "scope"
            }
        }
    }

    /// Frame to position against.
    let backdrop: Image

    /// Existing geometry to start from, when adjusting rather than placing fresh.
    let initialGeometry: HoopGeometry?

    let onCancel: () -> Void
    let onConfirm: (HoopGeometry) -> Void

    @State private var mode: Mode = .navigate

    // Zoom / pan. The `committed` values are what the last gesture settled on; the live
    // ones track the gesture in progress.
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    /// Box being dragged out for the first time, in image space.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    /// What the in-progress drag is doing, and the state it started from.
    @State private var activeGrab: RimBoxEditor.Grab?
    @State private var grabOriginBox: CGRect?
    @State private var grabOriginOffset: CGSize = .zero

    /// Committed box in normalized image space (origin top-left, y down) so it survives
    /// zoom, pan and layout changes. Converted to Vision space only on confirm.
    @State private var placedBox: CGRect?

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 12

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
                // outside the transform. In place mode the inner surface consumes the
                // drag first and this never fires.
                .gesture(panGesture(container: container.size))
                // Pinch stays live in both modes: zooming while placing is natural and
                // a two-finger pinch can't be confused with drawing a box.
                .simultaneousGesture(magnifyGesture(container: container.size))
                .onTapGesture(count: 2) { resetZoom() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Place the rim")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use rim") {
                        if let geometry = confirmedGeometry() {
                            onConfirm(geometry)
                        }
                    }
                    .disabled(confirmedGeometry() == nil)
                }
            }
            .onAppear(perform: seedFromExistingGeometry)
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
                        rimOverlay(size: image.size)

                        // Only hit-testable while placing, so in navigate mode touches
                        // fall through to the container's pan gesture.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(placementGesture(size: image.size))
                            .allowsHitTesting(mode == .place)
                    }
                }
            }
    }

    @ViewBuilder
    private func rimOverlay(size: CGSize) -> some View {
        if let box = activeBox(in: size) {
            // Stroke widths are divided by scale so they stay hairline-thin on screen
            // as you zoom in — a 2pt line at 8× would cover the rim you're aiming at.
            let line = 2 / scale

            Ellipse()
                .stroke(Color.orange, lineWidth: line)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)

            Rectangle()
                .stroke(Color.orange.opacity(0.35),
                        style: StrokeStyle(lineWidth: line * 0.6, dash: [3 / scale, 3 / scale]))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)

            // The scoring plane — what a shot has to cross downward to count.
            Path { path in
                path.move(to: CGPoint(x: box.minX, y: box.midY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            }
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: line, dash: [4 / scale, 3 / scale]))

            // Adjustment handles, once there is a committed box to adjust.
            if placedBox != nil, mode == .place, dragStart == nil {
                ForEach(RimBoxEditor.Handle.allCases, id: \.self) { handle in
                    let anchor = handle.point(in: box)
                    let isActive = activeGrab == .resize(handle)

                    Circle()
                        .fill(.white)
                        .overlay(
                            Circle().stroke(
                                handle.isHorizontal ? Color.orange : Color.cyan,
                                lineWidth: line
                            )
                        )
                        // Sized in image space so it stays a constant size on screen
                        // however far in you zoom.
                        .frame(width: handleDiameter, height: handleDiameter)
                        .scaleEffect(isActive ? 1.4 : 1)
                        .position(x: anchor.x, y: anchor.y)
                }
            }
        }
    }

    /// Handle diameter in image space — constant on screen at any zoom.
    private var handleDiameter: CGFloat { 18 / scale }

    /// Touch slop in image space — constant on screen at any zoom.
    private var handleHitRadius: CGFloat { 24 / scale }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

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

                // Redrawing is an explicit action rather than something a stray drag can
                // trigger, so a careful adjustment can't be wiped out by a mistimed touch.
                Button("Redraw", systemImage: "trash") {
                    placedBox = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(placedBox == nil)
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
                ? "Drag to pan · pinch to zoom · switch to Place Rim"
                : "Pinch to zoom in on the rim first"
        case .place:
            return placedBox == nil
                ? "Drag a box roughly around the rim"
                : "Drag the box to move · drag a bubble to resize · drag outside to pan"
        }
    }

    // MARK: Gestures

    private func placementGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let current = placedBox?.denormalized(in: size)

                // Classify once, on the first change, then stay committed to it — a
                // grab that re-evaluated every frame would jump between move and resize as
                // the finger crossed a handle.
                if activeGrab == nil {
                    activeGrab = RimBoxEditor.classify(
                        point: value.startLocation,
                        box: current,
                        hitRadius: handleHitRadius
                    )
                    grabOriginBox = current
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
                    guard let origin = grabOriginBox else { return }
                    let edited = RimBoxEditor.apply(
                        grab: activeGrab!,
                        origin: origin,
                        translation: value.translation,
                        bounds: size,
                        minimumSide: minimumSide(in: size)
                    )
                    placedBox = edited.normalized(in: size)

                case .none:
                    break
                }
            }
            .onEnded { value in
                if activeGrab == .draw {
                    let box = CGRect(from: value.startLocation, to: value.location)
                    let minSide = minimumSide(in: size)

                    if box.width > minSide, box.height > minSide / 2,
                       size.width > 0, size.height > 0 {
                        placedBox = RimBoxEditor
                            .containing(box, in: size)
                            .normalized(in: size)
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

    /// Smallest edge a box may have, in image space. Expressed against the image rather
    /// than the screen so a legitimately tiny rim box isn't rejected at high zoom.
    private func minimumSide(in size: CGSize) -> CGFloat {
        size.width * 0.005
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

    // MARK: Geometry

    /// Box currently being dragged, else the committed one.
    private func activeBox(in size: CGSize) -> CGRect? {
        if let start = dragStart, let current = dragCurrent {
            return CGRect(from: start, to: current)
        }
        guard let placedBox, size.width > 0, size.height > 0 else { return nil }
        return placedBox.denormalized(in: size)
    }

    private func confirmedGeometry() -> HoopGeometry? {
        guard let box = placedBox, box.width > 0, box.height > 0 else { return nil }
        return HoopGeometry(normalizedViewRect: box)
    }

    private func seedFromExistingGeometry() {
        guard placedBox == nil, let existing = initialGeometry else { return }
        placedBox = existing.normalizedViewRect
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
        CGRect(
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

/// Shown over the video when there is no scoring plane, because nothing can be tracked
/// without one — a silent failure here would look exactly like a detector that simply
/// never scores.
struct RimMissingBanner: View {
    let onPlace: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("No rim found")
                    .font(.caption.weight(.semibold))
                Text("Shots can't be scored until it's placed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Place", action: onPlace)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
