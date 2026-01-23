//
//  BallModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 12/01/2026.
//

import Foundation

let BALL_BUFFER_SIZE = 30 // frames

struct BallObservation {
    let frameID: Int
    let center: CGPoint
    let radius: CGFloat
    let confidence: CGFloat
}

enum BallState {
    // TODO
//    case dribbling
//    case passing
    
    case nonShooting
    case shooting
}

class BallModel {
    var history: RingBuffer<BallObservation> = RingBuffer(capacity: BALL_BUFFER_SIZE)
    
    var state: BallState = .nonShooting
    var locked: Bool = false
}


// From history of ball predictions, get the median average radius of the ball (prevent outlier detections from skewing ball size)
func smoothedRadius(history: RingBuffer<BallObservation>, window: Int = 5) -> Double {
    guard history.elements.isEmpty else {
        return 0
    }
    
    let radiuses: [Double] = history.suffix(window).map({ $0.radius }).sorted()
    let mid = radiuses.count / 2
    
    return radiuses.count % 2 == 0
        ? (radiuses[mid - 1] + radiuses[mid]) * 0.5
        : radiuses[mid]
}

// RMSE Root Mean Squared Error - square root of the average of squared differences
// Indication that the ball bounced off the rim (or some other occurance caused the ball trajectory to deviate/break motion fit)
func detectFitBreak(history: RingBuffer<BallObservation>, fit: MotionFit, threshold: Double = 14) -> Bool {
    guard history.elements.count >= 8 else { return false }
    
    let trajectorySnippet = history.suffix(8)
    var errors = trajectorySnippet.map { observation in
        let (predictedX, predictedY) = predictPosition(fit: fit, t: observation.frameID)
        return hypot(predictedX - observation.center.x, predictedY - observation.center.y)
    }
    
    let rmse = errors.reduce(0.0) { $0 + $1 } / Double(errors.count)
    return rmse > threshold
}

func detectShootingEntry(history: RingBuffer<BallObservation>, fit: MotionFit) -> Bool {
    guard history.elements.count >= 6 else { return false }
    
    let trajectorySnippet = history.suffix(6)
    let t = trajectorySnippet.map({ $0.frameID }) //time
    let y = trajectorySnippet.map({ $0.center.y }) //height
    
    let py = fit.py //polynomialFit
    
    // derived from quad fit
    // y(t)=at2+bt+c
    //      =
    // dy / dt = 2at + b
    let vyNow = (2 * py.0 * Double(t.last!)) + py.1 // velocityNow
    
    
    let upward = vyNow < -2.5
    
//    let upwardFrames = [Int]()
//    TODO: ony got here
    
    
    let upwardFrames = zip(y.dropFirst(), y)
           .filter { $0 < $1 }
           .count
    //
    let curvatureOk = py.0 < -0.02 * abs(py.1)
    
    
//       let curvatureOK = py.0 < -0.0005

       print("vy:", vyNow, "upward_frames:", upwardFrames, "py0:", py.0)

       return upward && upwardFrames >= 3 && curvatureOk
}

func isLikelyDribble(
    history: RingBuffer<BallObservation>,
    fit: MotionFit
) -> Bool {

    guard history.elements.count >= 8 else { return false }

    let pts = history.suffix(8)
    let t = pts.map { $0.frameID }
    let x = pts.map { $0.center.x }
    let y = pts.map { $0.center.y }

    let arcDuration = t.last! - t.first!
    if arcDuration < 6 {
        print("dribble: short arc")
        return true
    }

    let verticalRise = y.first! - y.min()!
    if verticalRise < 25 {
        print("dribble: low apex")
        return true
    }

    let horizontalDisp = abs(x.last! - x.first!)
    if horizontalDisp < 20 {
        print("dribble: low horizontal travel")
        return true
    }

    if fit.py.0 > 0.01 {
        print("dribble: strong curvature")
        return true
    }

    return false
}

func inferLateShot(
    history: RingBuffer<BallObservation>,
    fit: MotionFit,
    rim: HoopGeometry
) -> Bool {

    guard history.elements.count >= 6 else { return false }

    let py = fit.py
    let vyNow = 2 * py.0 * Double(history.suffix(1)[0].frameID) + py.1

    if vyNow < 5 { return false }

    let yNow = history.suffix(1)[0].center.y
    if yNow > rim.center.y + 20 { return false }

    let pts = history.suffix(6)
    let dx = pts.last!.center.x - pts.first!.center.x
    if abs(dx) < 5 { return false }

    return true
}

func findYCrossingTime(
    fit: MotionFit,
    yTarget: Double,
    t0: Double,
    t1: Double,
    steps: Int = 60
) -> Double? {

    let dt = (t1 - t0) / Double(steps)

    for i in 0...steps {
        let t = t0 + Double(i) * dt
        let (_, y) = predictPosition(fit: fit, t: Int(t))
        if y > yTarget {
            return t
        }
    }

    return nil
}

func fitQualityScore(
    fit: MotionFit,
    history: RingBuffer<BallObservation>,
    sigma: Double = 7.0,
    window: Int = 10
) -> Double {

    guard history.elements.count >= 5 else { return 0.0 }

    let pts = history.suffix(window)

    var errorSum: Double = 0.0
    var count: Double = 0.0

    for p in pts {
        let (xHat, yHat) = predictPosition(fit: fit, t: p.frameID)
        let dx = xHat - p.center.x
        let dy = yHat - p.center.y
        errorSum += hypot(dx, dy)
        count += 1.0
    }

    let rmse = errorSum / count
    return exp(-rmse / sigma)
}

func shotConfidence(
    fit: MotionFit,
    rimGeom: HoopGeometry,
    tNow: Double,
    ballHistory: RingBuffer<BallObservation>
) -> (Double, [String: Double]) {

    let ts = linspace(tNow - 2.0, tNow + 5.0, 30)

    var insideFrames = 0
    var clearanceScores: [Double] = []
    var vyScores: [Double] = []

    let ballR = smoothedRadius(history: ballHistory)

    let py = fit.py

    for t in ts {
        let (x, y) = predictPosition(fit: fit, t: Int(t))

        let clearance = ellipseBallClearance(
            ballX: x,
            ballY: y,
            ballRadius: ballR,
            hoop: rimGeom
        )

        let vy = 2.0 * py.0 * t + py.1

        // Physically valid make conditions
        if vy > 0 && clearance > -0.15 {
            insideFrames += 1

            clearanceScores.append(
                clamp01(value: clearance / 0.25)
            )

            vyScores.append(
                clamp01(value: (vy - 0.5) / 6.0)
            )
        }
    }

    guard insideFrames > 0 else {
        return (0.0, [:])
    }

    let clearanceScore = clearanceScores.reduce(0, +) / Double(clearanceScores.count)
    let crossing = clamp01(value: Double(insideFrames) / 3.0)
    let vyScore = vyScores.reduce(0, +) / Double(vyScores.count)
    let fitScore = fitQualityScore(fit: fit, history: ballHistory)
    let persistence = clamp01(value: Double(insideFrames) / 4.0)

    let confidence =
        0.40 * clearanceScore +
        0.25 * crossing +
        0.15 * vyScore +
        0.15 * fitScore +
        0.05 * persistence

    return (
        clamp01(value: confidence),
        [
            "clearance": clearanceScore,
            "crossing": crossing,
            "vy": vyScore,
            "fit": fitScore,
            "persistence": persistence
        ]
    )
}
