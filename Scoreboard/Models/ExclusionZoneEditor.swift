//
//  ExclusionZoneEditor.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import Foundation

/// Hit-testing and space conversion for the blocked-area editor.
///
/// Pure and free of SwiftUI, for the same reason `RimBoxEditor` is: gesture maths inside
/// a view body can only be checked by hand on a device, and a y-flip that is quietly
/// upside down produces zones that look right while blocking the wrong part of the frame.
///
/// Two spaces are in play, and mixing them is the mistake worth guarding against:
///
///  - **Image space** — normalized, origin top-left, y down. What a drag reports, and
///    what the editor holds while the user works, so zones survive zoom, pan and layout.
///  - **Vision space** — normalized, origin bottom-left, y up. What every observation and
///    stored `ExclusionZone` uses.
enum ExclusionZoneEditor {

    /// The zone under a point, in normalized image space.
    ///
    /// Later zones win: they are drawn on top, so they are what the user is pointing at.
    static func index(
        at point: CGPoint,
        in boxes: [CGRect],
        slop: CGFloat = 0
    ) -> Int? {
        boxes.lastIndex { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// Whether a dragged-out box is worth keeping, or was really a tap.
    static func isBigEnough(_ box: CGRect, minimumSide: CGFloat) -> Bool {
        box.standardized.width >= minimumSide && box.standardized.height >= minimumSide
    }

    /// Image space to Vision space. The y-flip is the whole job: a rect's *top* edge in
    /// image space is its *maximum* y in Vision space.
    static func visionRect(fromImage rect: CGRect) -> CGRect {
        let upright = rect.standardized

        return CGRect(
            x: upright.minX,
            y: 1 - upright.maxY,
            width: upright.width,
            height: upright.height
        )
    }

    /// Vision space back to image space. Its own inverse.
    static func imageRect(fromVision rect: CGRect) -> CGRect {
        let upright = rect.standardized

        return CGRect(
            x: upright.minX,
            y: 1 - upright.maxY,
            width: upright.width,
            height: upright.height
        )
    }
}
