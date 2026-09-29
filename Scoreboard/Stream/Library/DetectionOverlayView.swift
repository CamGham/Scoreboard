//
//  DetectionOverlayView.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import SwiftUI

/// What the detector is seeing, drawn over the frame it saw it in.
///
/// Every value read here is rewritten by the tracker on each frame, so this view redraws
/// as fast as frames arrive. That is the whole cost of watching an analysis — which is
/// why it is only ever in the hierarchy while somebody is actually watching one.
///
/// Shared by the first pass and by a re-analysis of a marked section: both are the same
/// detector over the same kind of frames, and a second copy of this would be a second
/// place for the drawing to drift from what the detector actually did.
struct DetectionOverlayView: View {

    let processor: VideoProcessor

    /// The running tally and detector status, centred at the top. Off for a re-analysis,
    /// where the totals belong to the whole clip rather than to the window being redone.
    var showsReadout = true

    var body: some View {
        GeometryReader { geometry in
            ForEach(processor.tracker.rects) { rectData in
                let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                Rectangle()
                    .stroke(rectData.colour, lineWidth: 2)
                    .frame(width: adjustedRect.width, height: adjustedRect.height)
                    .position(x: adjustedRect.midX, y: adjustedRect.midY)

                Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                    .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                    .foregroundColor(.red)
            }
            ForEach(processor.tracker.trackedRects) { rectData in
                let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                Rectangle()
                    .stroke(rectData.colour, lineWidth: 2)
                    .frame(width: adjustedRect.width, height: adjustedRect.height)
                    .position(x: adjustedRect.midX, y: adjustedRect.midY)
                
                Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                    .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                    .foregroundColor(.red)
            }
            let gameState = processor.tracker.gameState

            // The ball is detected rather than tracked, so it is
            // drawn from its own sighting instead of the track list.
            if let ball = processor.tracker.ballRect {
                let adjusted = adjustRectForView(rect: ball.rect, viewSize: geometry.size)
                Rectangle()
                    .stroke(ball.colour, lineWidth: 2)
                    .frame(width: adjusted.width, height: adjusted.height)
                    .position(x: adjusted.midX, y: adjusted.midY)
            }

            // Live ball position. `center` is a true centre now, so
            // the circle is built symmetrically around it.
            if let currentBall = gameState.ballHistory.last {
                let ballRect = CGRect(
                    x: currentBall.center.x - currentBall.radius,
                    y: currentBall.center.y - currentBall.radius,
                    width: currentBall.radius * 2,
                    height: currentBall.radius * 2
                )
                let adjustedRect = adjustRectForView(rect: ballRect, viewSize: geometry.size)
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: adjustedRect.width, height: adjustedRect.height)
                    .position(x: adjustedRect.midX, y: adjustedRect.midY)
            }

            // Fitted arc, drawn only while a shot is live.
            if !gameState.arcPoints.isEmpty {
                Path { path in
                    let points = gameState.arcPoints.map {
                        normalizedToView($0, viewSize: geometry.size)
                    }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // The scoring plane the make/miss verdict is measured against.
            if let hoopGeometry = gameState.rim {
                let ellipseRect = adjustedEllipseFrame(
                    center: hoopGeometry.center,
                    radiusX: hoopGeometry.horizontalRadius,
                    radiusY: hoopGeometry.verticalRadius,
                    viewSize: geometry.size
                )

                Path { path in
                    path.addEllipse(in: ellipseRect)
                }
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                Path { path in
                    let y = (1 - hoopGeometry.scoringPlaneY) * geometry.size.height
                    path.move(to: CGPoint(x: hoopGeometry.leftX * geometry.size.width, y: y))
                    path.addLine(to: CGPoint(x: hoopGeometry.rightX * geometry.size.width, y: y))
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }

            if showsReadout {
                LiveShotReadout(gameState: gameState)
                    .position(x: geometry.size.width / 2, y: 40)
            }

            if let hoop = processor.tracker.hoop.first {
                let adjustedRect = adjustRectForView(rect: hoop.rect, viewSize: geometry.size)
                Rectangle()
                    .stroke(hoop.colour, lineWidth: 2)
                    .frame(width: adjustedRect.width, height: adjustedRect.height)
                    .position(x: adjustedRect.midX, y: adjustedRect.midY)
//                                    Text("\(hoop.label) \(hoop.id)")
//                                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
//                                        .foregroundColor(.red)
                Text("\(hoop.label) (\(Int(hoop.confidence * 100))%)")
                    .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                    .foregroundColor(.red)
            }
        }
    }

    private func adjustRectForView(rect: CGRect, viewSize: CGSize) -> CGRect {
        
        let width = rect.width * viewSize.width
        let height = rect.height * viewSize.height
        
        let x = rect.origin.x * viewSize.width
        let y = (1 - rect.origin.y - rect.height) * viewSize.height
        return CGRect(x: x, y: y, width: width, height: height)
        
//        let scale = CGAffineTransform.identity.scaledBy(x: viewSize.width, y: viewSize.height)
//        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -viewSize.height)
//        return rect.applying(scale).applying(transform)
    }

    private func adjustedEllipseFrame(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, viewSize: CGSize) -> CGRect {
        let cx = center.x * viewSize.width
        let cy = (1 - center.y) * viewSize.height // flip Y to match image space used elsewhere
        let rx = radiusX * viewSize.width
        let ry = radiusY * viewSize.height
        return CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
    }

    private func normalizedToView(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * viewSize.width, y: (1 - point.y) * viewSize.height)
    }
}
