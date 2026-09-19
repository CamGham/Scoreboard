//
//  RimBoxEditor.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation

/// Hit-testing and resize maths for the rim placement box.
///
/// Pure and free of SwiftUI so it can be tested directly — a resize that quietly
/// inverts a rect or lets an edge escape the frame produces a rim that looks plausible
/// on screen but skews every make/miss verdict, which is not a thing to find out from a
/// video.
///
/// Everything here works in *image-space points* (origin top-left, y down), the space
/// the placement gesture reports in.
enum RimBoxEditor {

    /// Mid-edge handles. Each moves one edge, leaving the other three where they are.
    ///
    /// Independent edges rather than symmetric-about-centre: aligning the left edge to
    /// the left of the rim and the right edge to the right is one pass, and the centre —
    /// which is the scoring plane — falls out correctly. Resizing about the centre would
    /// mean alternating move and resize to converge on the same result.
    enum Handle: CaseIterable, Equatable {
        case leading, trailing, top, bottom

        func point(in box: CGRect) -> CGPoint {
            switch self {
            case .leading:  return CGPoint(x: box.minX, y: box.midY)
            case .trailing: return CGPoint(x: box.maxX, y: box.midY)
            case .top:      return CGPoint(x: box.midX, y: box.minY)
            case .bottom:   return CGPoint(x: box.midX, y: box.maxY)
            }
        }

        /// Whether this handle changes the rim's width (and so its horizontal radius).
        var isHorizontal: Bool {
            self == .leading || self == .trailing
        }
    }

    enum Grab: Equatable {
        /// Start a fresh box — there isn't one yet.
        case draw
        /// Move the whole box.
        case move
        /// Move one edge.
        case resize(Handle)
        /// Nothing grabbed; the drag should pan the view instead.
        case pan
    }

    /// What a drag starting at `point` should do.
    ///
    /// Handles are checked before the body so that a grab near a corner of the box
    /// resizes rather than moves.
    static func classify(
        point: CGPoint,
        box: CGRect?,
        hitRadius: CGFloat
    ) -> Grab {

        guard let box else { return .draw }

        for handle in Handle.allCases {
            let anchor = handle.point(in: box)
            if hypot(point.x - anchor.x, point.y - anchor.y) <= hitRadius {
                return .resize(handle)
            }
        }

        // A little slack around the body, because a thin rim box is a small target.
        if box.insetBy(dx: -hitRadius * 0.5, dy: -hitRadius * 0.5).contains(point) {
            return .move
        }

        return .pan
    }

    /// Apply a drag to the box that was current when the drag began.
    ///
    /// Working from the box at drag start rather than accumulating deltas keeps the
    /// result exact — accumulating would drift as each frame re-clamps.
    static func apply(
        grab: Grab,
        origin: CGRect,
        translation: CGSize,
        bounds: CGSize,
        minimumSide: CGFloat
    ) -> CGRect {

        switch grab {
        case .draw, .pan:
            return origin

        case .move:
            let moved = origin.offsetBy(dx: translation.width, dy: translation.height)
            return containing(moved, in: bounds)

        case .resize(let handle):
            return resize(origin, handle: handle, by: translation, bounds: bounds, minimumSide: minimumSide)
        }
    }

    private static func resize(
        _ box: CGRect,
        handle: Handle,
        by translation: CGSize,
        bounds: CGSize,
        minimumSide: CGFloat
    ) -> CGRect {

        var minX = box.minX
        var maxX = box.maxX
        var minY = box.minY
        var maxY = box.maxY

        switch handle {
        case .leading:
            // Clamped so the edge can neither cross its opposite nor leave the frame.
            minX = min(max(box.minX + translation.width, 0), maxX - minimumSide)
        case .trailing:
            maxX = max(min(box.maxX + translation.width, bounds.width), minX + minimumSide)
        case .top:
            minY = min(max(box.minY + translation.height, 0), maxY - minimumSide)
        case .bottom:
            maxY = max(min(box.maxY + translation.height, bounds.height), minY + minimumSide)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Slide a box back inside the frame without changing its size.
    static func containing(_ box: CGRect, in bounds: CGSize) -> CGRect {
        var result = box

        if result.maxX > bounds.width { result.origin.x -= result.maxX - bounds.width }
        if result.minX < 0 { result.origin.x = 0 }
        if result.maxY > bounds.height { result.origin.y -= result.maxY - bounds.height }
        if result.minY < 0 { result.origin.y = 0 }

        return result
    }
}
