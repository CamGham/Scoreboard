//
//  CameraModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 18/09/2024.
//

import Foundation
import AVFoundation
import CoreImage
import Vision
import Combine
import UIKit
import SwiftUI
import LASwift

@Observable
final class CameraModel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var previewSource: PreviewSource { captureService.previewSource }
    let captureService = CaptureService()
    
    // should look for new objects every 10 sec
    let predictionTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()
    // can run observations every 0.05 sec to avoid over-processing
    let observationTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    var dontCareAboutPerformance = true // override observation limit
    
    var tracker = VisionTracker()
   
    override init() {
        super.init()
        
        Task {
            await captureService.setOutputDelegate(source: self)
        }
    }
    
    func start() async {
        guard await captureService.isAuthorized else {
            return
        }
        do {
            try await captureService.start()
        } catch {
            print("Failed to start camera")
        }
    }
    
    deinit {
        print("closing")
    }
    
    func stop() async {
        await captureService.stop()
        self.tracker.requests.removeAll()
        self.tracker.rects.removeAll()
    }
    
    
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = sampleBuffer.imageBuffer else { return }

        do {
            let orientation = exifOrientationFromDeviceOrientation()
            // TODO: upgrade with ball priority tracking
            if tracker.shouldPredict {
                tracker.shouldPredict = false
                try tracker.makeObservations(pixelBuffer: buf, orientation: orientation)
            } else if tracker.canObserve || dontCareAboutPerformance {
                tracker.canObserve = false
                try tracker.trackObservations(pixelBuffer: buf, orientation: orientation)
            }
        } catch {
            print("Failed to make observations")
        }
    }
    
    public func exifOrientationFromDeviceOrientation() -> CGImagePropertyOrientation {
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation: CGImagePropertyOrientation
        
        switch curDeviceOrientation {
        case UIDeviceOrientation.portraitUpsideDown:  // Device oriented vertically, home button on the top
            exifOrientation = .left
        case UIDeviceOrientation.landscapeLeft:       // Device oriented horizontally, home button on the right
            exifOrientation = .up
        case UIDeviceOrientation.landscapeRight:      // Device oriented horizontally, home button on the left
            exifOrientation = .down
        case UIDeviceOrientation.portrait:            // Device oriented vertically, home button on the bottom
            exifOrientation = .right
        default:
            exifOrientation = .right
        }
        return exifOrientation
    }
}

struct RectangleData: Identifiable {
    let id: UUID
    let rect: CGRect
    let label: String
    let confidence: Float
    let colour: Color
}
