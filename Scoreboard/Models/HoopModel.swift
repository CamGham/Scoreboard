//
//  HoopModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 17/01/2026.
//

import Foundation

/// The rim, in Vision normalized image space (origin bottom-left, y up).
///
/// A basketball rim viewed from anywhere but directly side-on projects to an ellipse:
/// wide horizontally, squashed vertically by the camera's elevation angle.
/// `center` is the true centre of that ellipse — NOT a bounding-box corner.
struct HoopGeometry: Codable, Equatable {
    let center: CGPoint
    let verticalRadius: CGFloat
    let horizontalRadius: CGFloat

    /// The horizontal plane a made shot must pass down through.
    var scoringPlaneY: CGFloat { center.y }

    var leftX: CGFloat { center.x - horizontalRadius }
    var rightX: CGFloat { center.x + horizontalRadius }

    var topY: CGFloat { center.y + verticalRadius }
    var bottomY: CGFloat { center.y - verticalRadius }

    /// Bounding box in Vision space (origin bottom-left), handy for overlays.
    var boundingBox: CGRect {
        CGRect(
            x: center.x - horizontalRadius,
            y: center.y - verticalRadius,
            width: horizontalRadius * 2,
            height: verticalRadius * 2
        )
    }

    init(center: CGPoint, verticalRadius: CGFloat, horizontalRadius: CGFloat) {
        self.center = center
        self.verticalRadius = verticalRadius
        self.horizontalRadius = horizontalRadius
    }

    /// Build from a rect in normalized *view* space (origin top-left, y down) — the
    /// space SwiftUI drags land in.
    ///
    /// Kept here rather than inside the placement view so the flip has one definition
    /// and can be tested for round-trip fidelity. Getting it wrong would mirror the rim
    /// vertically, which on a centred hoop looks almost right and silently biases every
    /// verdict.
    init(normalizedViewRect rect: CGRect) {
        self.init(
            boundingBox: CGRect(
                x: rect.minX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        )
    }

    /// The inverse of `init(normalizedViewRect:)`.
    var normalizedViewRect: CGRect {
        let box = boundingBox
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Build from a detector bounding box (Vision space, origin bottom-left).
    init(boundingBox: CGRect) {
        self.init(
            center: CGPoint(x: boundingBox.midX, y: boundingBox.midY),
            verticalRadius: boundingBox.height / 2,
            horizontalRadius: boundingBox.width / 2
        )
    }
}

/// Signed clearance between a ball and the rim ellipse.
///
/// The ellipse is shrunk by the ball's radius first, because we are testing whether a
/// ball of finite size fits through an opening — not whether a dimensionless point
/// lands inside it.
///
///  - `> 0` : the ball passes cleanly
///  - `= 0` : grazing the rim
///  - `< 0` : the ball would collide with the rim
func ellipseBallClearance(
    ballX: Double,
    ballY: Double,
    ballRadius: Double,
    hoop: HoopGeometry
) -> Double {
    let dx = ballX - hoop.center.x
    let dy = ballY - hoop.center.y

    let effectiveHorizontal = max(hoop.horizontalRadius - ballRadius, 1e-4)
    let effectiveVertical = max(hoop.verticalRadius - ballRadius, 1e-4)

    let ellipseNormalised =
        ((dx * dx) / (effectiveHorizontal * effectiveHorizontal)) +
        ((dy * dy) / (effectiveVertical * effectiveVertical))

    return 1.0 - ellipseNormalised
}

/// Accumulates rim detections into one stable geometry.
///
/// The rim doesn't move, but the detector's box for it jitters frame to frame and
/// occasionally lands on a backboard edge or a second hoop. Writing every detection
/// straight into game state (as the pipeline used to) means the scoring plane wobbles
/// underneath an in-flight shot. Taking a running median over recent detections gives a
/// rim that is both stable and still able to follow a genuine camera move.
struct RimTracker {

    /// Where the current geometry came from.
    enum Source: Equatable {
        case detected
        /// Positioned by the user. Outranks the detector permanently.
        case userPlaced
    }

    /// Detections to keep before the rim is considered locked.
    private let sampleCapacity: Int

    /// Detections needed before `geometry` is published at all.
    ///
    /// One, deliberately. Rim detections are scarce — the pipeline only runs the
    /// detector on a fraction of frames — so withholding the rim until several have
    /// arrived can mean no scoring plane for most of a clip. Publishing immediately and
    /// refining as more samples land is strictly better: the estimate is available from
    /// the first sighting and only improves.
    private let minimumSamples: Int

    /// A detection this far (in rim widths) from the established rim is treated as a
    /// different object — a second hoop, a backboard edge — and ignored.
    private let rejectionDistanceInWidths: CGFloat

    /// Outlier rejection only switches on once this many samples agree. Rejecting
    /// against a single sample would let one bad first detection lock out every real
    /// rim that followed.
    private let rejectionActiveAfter = 3

    private var samples: [CGRect] = []

    private(set) var geometry: HoopGeometry?

    private(set) var source: Source = .detected

    /// Frame of the most recently accepted detection.
    private(set) var lastUpdatedFrame: Int?

    init(
        sampleCapacity: Int = 31,
        minimumSamples: Int = 1,
        rejectionDistanceInWidths: CGFloat = 1.5
    ) {
        self.sampleCapacity = sampleCapacity
        self.minimumSamples = minimumSamples
        self.rejectionDistanceInWidths = rejectionDistanceInWidths
    }

    var isLocked: Bool {
        source == .userPlaced || (geometry != nil && samples.count >= sampleCapacity)
    }

    var isUserPlaced: Bool { source == .userPlaced }

    /// Pin the rim to a geometry the user positioned by hand.
    ///
    /// This wins outright: detections stop being accepted afterwards. The user can see
    /// the rim and the detector evidently could not, so letting a later low-confidence
    /// box drag the scoring plane off their placement would only undo their work.
    mutating func setUserPlaced(_ geometry: HoopGeometry) {
        self.geometry = geometry
        self.source = .userPlaced
        self.samples = [geometry.boundingBox]
    }

    /// Hand control back to the detector, discarding a manual placement.
    mutating func clearUserPlacement() {
        source = .detected
        samples.removeAll()
        geometry = nil
    }

    /// Feed a rim detection. Returns true when it was accepted as the same rim.
    @discardableResult
    mutating func observe(boundingBox: CGRect, frameID: Int) -> Bool {
        guard source != .userPlaced else { return false }
        guard boundingBox.width > 0, boundingBox.height > 0 else { return false }

        if let current = geometry, samples.count >= rejectionActiveAfter {
            let dx = boundingBox.midX - current.center.x
            let dy = boundingBox.midY - current.center.y
            let reach = max(current.horizontalRadius * 2, 1e-4) * rejectionDistanceInWidths

            if hypot(dx, dy) > reach {
                // Almost certainly a different object. Ignore it rather than let it
                // drag the scoring plane across the frame.
                return false
            }
        }

        samples.append(boundingBox)
        if samples.count > sampleCapacity {
            samples.removeFirst(samples.count - sampleCapacity)
        }

        lastUpdatedFrame = frameID

        guard samples.count >= minimumSamples else { return true }

        // Median each component independently: robust to the occasional box that
        // snaps to the backboard without needing outlier rejection.
        let cx = median(samples.map { Double($0.midX) })!
        let cy = median(samples.map { Double($0.midY) })!
        let w = median(samples.map { Double($0.width) })!
        let h = median(samples.map { Double($0.height) })!

        geometry = HoopGeometry(
            center: CGPoint(x: cx, y: cy),
            verticalRadius: h / 2,
            horizontalRadius: w / 2
        )

        return true
    }

    mutating func reset() {
        samples.removeAll()
        geometry = nil
        source = .detected
        lastUpdatedFrame = nil
    }
}
