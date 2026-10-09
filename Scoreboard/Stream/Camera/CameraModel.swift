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
        await MainActor.run { tracker.playerTracks.removeAll() }
    }
    
    
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = sampleBuffer.imageBuffer else { return }

        PipelineSignpost.measure("Frame") {
            let orientation = exifOrientationFromDeviceOrientation()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            tracker.beginFrame(timeSeconds: presentationTime.isValid ? presentationTime.seconds : nil)
            tracker.detect(pixelBuffer: buf, orientation: orientation)
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
