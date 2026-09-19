//
//  BallROIPredictor.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/09/2026.
//

import Foundation

/// Works out where to look for the ball next, and how big a window to look in.
///
/// A basketball in a wide court frame is tiny — roughly 46px in a 1920-wide frame — and
/// `.scaleFit` into the model's 640×640 input shrinks it to about 15px while wasting 44%
/// of the input on letterbox bars. Detecting inside a small square crop instead puts the
/// same ball at ~60px with no wasted input: about 4× linear, 16× by area.
///
/// Pure and free of Vision so the geometry can be tested directly. All rects are in
/// Vision normalized space (origin bottom-left, y up).
enum BallROIPredictor {

    struct Config {
        /// Side of the crop as a fraction of frame *width*, before any growth.
        ///
        /// A shot crosses maybe 3–5% of the frame per frame, so a quarter-width window
        /// leaves generous margin for both motion and prediction error.
        var baseSideFraction: Double = 0.25

        /// How much the window grows per consecutive miss. Prediction error compounds
        /// while the ball is unseen, so the search area has to keep up.
        var growthPerMiss: Double = 0.35

        var maxSideFraction: Double = 0.75

        /// Consecutive misses before giving up on the crop and sweeping the full frame.
        var missesBeforeFullFrame: Int = 6

        /// Above this fit error the parabola is not trusted for extrapolation and the
        /// predictor falls back to plain linear motion.
        var maxFitRMSE: Double = 0.02

        init() {}
    }

    // MARK: Where to look

    /// Predicted ball centre at `frame`, in Vision normalized space.
    ///
    /// Prefers the ballistic fit when it is genuinely ballistic and fitting well — a
    /// parabola under gravity is a physics prior, which beats extrapolating a straight
    /// line through the last two sightings. Falls back to linear motion otherwise,
    /// because a ball being dribbled or carried is not on a free-flight arc.
    static func predictedCentre(
        history: [BallObservation],
        fit: MotionFit?,
        atFrame frame: Int,
        config: Config = Config()
    ) -> CGPoint? {

        guard let newest = history.last else { return nil }

        if let fit, fit.isBallistic, fit.rmse <= config.maxFitRMSE, history.count >= 5 {
            let predicted = predictPosition(fit: fit, t: Double(frame))
            if predicted.x.isFinite, predicted.y.isFinite {
                return CGPoint(x: predicted.x, y: predicted.y)
            }
        }

        if history.count >= 2 {
            let previous = history[history.count - 2]
            let span = Double(newest.frameID - previous.frameID)

            if span > 0 {
                let step = Double(frame - newest.frameID) / span
                return CGPoint(
                    x: newest.center.x + (newest.center.x - previous.center.x) * step,
                    y: newest.center.y + (newest.center.y - previous.center.y) * step
                )
            }
        }

        return newest.center
    }

    // MARK: How big a window

    static func sideFraction(consecutiveMisses: Int, config: Config = Config()) -> Double {
        let grown = config.baseSideFraction *
            (1.0 + (Double(max(consecutiveMisses, 0)) * config.growthPerMiss))
        return min(grown, config.maxSideFraction)
    }

    /// A crop that is square *in pixels*, centred on `centre` and clamped to the frame.
    ///
    /// Square in pixels, not in normalized units: a normalized square on a 16:9 frame is
    /// a wide rectangle, which would reintroduce the letterboxing this is meant to avoid.
    /// So the normalized height is scaled by the frame's aspect ratio.
    ///
    /// - Parameter aspect: frame width ÷ height, of the *oriented* image.
    static func regionOfInterest(
        around centre: CGPoint,
        sideFraction: Double,
        aspect: Double
    ) -> CGRect {

        guard aspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // Same pixel extent horizontally and vertically.
        var width = sideFraction
        var height = sideFraction * aspect

        // A crop can't exceed the frame. Shrink the square as a whole so it stays square.
        if height > 1 {
            let scale = 1 / height
            height = 1
            width *= scale
        }
        if width > 1 {
            let scale = 1 / width
            width = 1
            height *= scale
        }

        // Slide inside the frame rather than shrinking, so magnification — and with it
        // detection behaviour — stays constant wherever the ball is.
        let x = min(max(centre.x - (width / 2), 0), 1 - width)
        let y = min(max(centre.y - (height / 2), 0), 1 - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Mapping results back

    /// Vision reports observations from a request with a region of interest in
    /// coordinates normalized *to that region*, so they have to be projected back into
    /// full-frame normalized space before anything downstream sees them.
    static func mapToFullFrame(roiRelative rect: CGRect, roi: CGRect) -> CGRect {
        CGRect(
            x: roi.minX + (rect.minX * roi.width),
            y: roi.minY + (rect.minY * roi.height),
            width: rect.width * roi.width,
            height: rect.height * roi.height
        )
    }
}
