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

@Observable
final class CameraModel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var previewSource: PreviewSource { captureService.previewSource }
    let captureService = CaptureService()
    
    var canPredict = false
    let predictionTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    var bufferSize: CGSize = .zero
    var rects: [RectangleData] = []
    var visionModel: VNCoreMLModel?

    override init() {
        super.init()
        Task {
            await captureService.setOutputDelegate(source: self)
            await visionModel = try ObjectDetector.createDetector()
        }
    }
    
    func start() async {
        guard await captureService.isAuthorized else {
            return
        }
        do {
            try await captureService.start()
            observeOrientation()
        } catch {
            
        }
    }
    
    func makeObservations(pixelBuffer: CVImageBuffer) async {
        guard canPredict else { return }
        
        Task { @MainActor in
            canPredict = false
        }
    
        Task {
            let orientation = exifOrientationFromDeviceOrientation()
            let vnHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            guard let visionModel else { return }
            
            let objectDetc = VNCoreMLRequest(model: visionModel) { vnReq, error in
                if let results = vnReq.results {
                    self.drawVisionRequestResults(results)
                }
            }
        
            do {
                try vnHandler.perform([objectDetc])
            } catch {
                print("failed")
            }

            
            // instance doesnt work
//            let handler = ImageRequestHandler(pixelBuffer)
//            
//            
//            let req = try await handler.perform(GeneratePersonInstanceMaskRequest())
//            guard let req else {
//                return
//            }
//            do {
//                
//                print("Current instances = \(req.allInstances.count)")
//                print("Confidence = \(req.allInstancesMask.confidence)")
//                
//                
//                Task { @MainActor in
//                    
//                    myImage = try req.allInstancesMask.cgImage
//                    
//                }
//            } catch {
//                
//            }
            
            
            
            // memory safe
//            let vnHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
//            
//            let vnSegmentationReq = VNGeneratePersonSegmentationRequest()
//            vnSegmentationReq.qualityLevel = .fast
//            
//            try vnHandler.perform([vnSegmentationReq])
//            
//            
//            if let buff = vnSegmentationReq.results?.first?.pixelBuffer {
//                
//                let ciImage = CIImage(cvPixelBuffer: buff)
//                   let context = CIContext()
//                   if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
//                       Task { @MainActor in
//                           myImage = cgImage
//                       }
//                   }
//            }
//            
            
            
            // not mem safe seg
//            let vnReq = VNGeneratePersonSegmentationRequest { nvReq, error in
//                nvReq.qua
//            }
//            
//            
//            let handler = ImageRequestHandler(pixelBuffer)
//            
//            let req = try await handler.perform(GeneratePersonSegmentationRequest(frameAnalysisSpacing: CMTime(seconds: 1, preferredTimescale: CMTimeScale())))
//            
//            do {
//                let res = try req.cgImage
//                
//                Task { @MainActor in
//                    myImage = res
//                }
//                
//            } catch {
//                
//            }
            
            // image class
//            let req = try await handler.perform(ClassifyImageRequest())
//            
//            let res = req.filter { ob in
//                ob.hasMinimumRecall(0.01, forPrecision: 0.9)
//            }
//            
//            Task { @MainActor in
//                myLabel = res.first?.identifier ?? "Unknown"
//            }
        }
    }
    
    func drawVisionRequestResults(_ results: [Any]) {
        var tempRects: [RectangleData] = []
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            // Select only the label with the highest confidence.
            let topLabelObservation = objectObservation.labels[0]
            let objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(bufferSize.width), Int(bufferSize.height))
            
            let rectangleData = RectangleData(
                                        rect: objectBounds,
                                        label: topLabelObservation.identifier,
                                        confidence: topLabelObservation.confidence
                                    )
            print("\(rectangleData.label) at \(rectangleData.confidence)")
            print("\(rectangleData.rect)")
            tempRects.append(rectangleData)
        }
        Task { @MainActor in
            rects = tempRects
        }
    }
    
    public func exifOrientationFromDeviceOrientation() -> CGImagePropertyOrientation {
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation: CGImagePropertyOrientation
        
        switch curDeviceOrientation {
        case UIDeviceOrientation.portraitUpsideDown:  // Device oriented vertically, home button on the top
            exifOrientation = .left
        case UIDeviceOrientation.landscapeLeft:       // Device oriented horizontally, home button on the right
            exifOrientation = .upMirrored
        case UIDeviceOrientation.landscapeRight:      // Device oriented horizontally, home button on the left
            exifOrientation = .down
        case UIDeviceOrientation.portrait:            // Device oriented vertically, home button on the bottom
            exifOrientation = .right
        default:
            exifOrientation = .up
        }
        return exifOrientation
    }
    
    private func observeOrientation() {
        Task {
            await updatePixelBufferSize()
            for await orientation in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                await updatePixelBufferSize()
            }
        }
    }
    
    func updatePixelBufferSize() async {
        print("updatin orientation")
        do {
            try await captureService.updateBufferDimensions()
            bufferSize = await captureService.bufferSize
        } catch {
            
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = sampleBuffer.imageBuffer else { return }

        Task {
            await makeObservations(pixelBuffer: buf)
        }
    }
}

struct RectangleData: Identifiable {
    let id = UUID()
    let rect: CGRect
    let label: String
    let confidence: Float
}
