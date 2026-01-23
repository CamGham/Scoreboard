//
//  HoopModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 17/01/2026.
//

import Foundation

struct HoopGeometry {
    let center: CGPoint
    let verticalRadius: CGFloat
    let horizontalRadius: CGFloat
}

func ellipseBallClearance(ballX: Double, ballY: Double, ballRadius: Double, hoop: HoopGeometry) -> Double {
    let xDistanceFromBallToHoop = ballX - hoop.center.x
    let yDistanceFromBallToHoop = ballY - hoop.center.y
    
    // shrink horizontal radius of hoop
    // we do this since we are determining if a point existing within the ellipse
    // A point does not account for ball radius, so we will shrink the ellipse to account for the ball
    let shrunkHorizontalRadius = hoop.horizontalRadius - (0.2 * ballRadius)
    
    let ellipseNormalised = ((xDistanceFromBallToHoop * xDistanceFromBallToHoop) / (shrunkHorizontalRadius * shrunkHorizontalRadius)) + ((yDistanceFromBallToHoop * yDistanceFromBallToHoop) / (hoop.verticalRadius * hoop.verticalRadius))
    
    
    // > 0 : ball fits
    // = 0 : grazing
    // < 0 : collision / impossible
    return 1.0 - ellipseNormalised
}
