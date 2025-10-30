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
    
    var canPredict = true
    let predictionTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    var visionModel: VNCoreMLModel?
    private var requests = [VNRequest]()
    var rects: [RectangleData] = []
    
    // TODO: Track objects over multiple frames
//    var rectangles = [UUID: RectangleData]()
//    var observations = [UUID: VNDetectedObjectObservation]()
//    let sequenceHandler = VNSequenceRequestHandler()
//    var startingOb: VNDetectedObjectObservation?
//    let requestHandler = VNSequenceRequestHandler()
    
    
    var gameState = GameState()

 
    override init() {
        super.init()
        
        Task {
            await captureService.setOutputDelegate(source: self)
            await visionModel = try ObjectDetector.createDetector()
            if let visionModel {
                setupVision(model: visionModel)
            }
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
        self.requests.removeAll()
        self.rects.removeAll()
    }
    
    func setupVision(model: VNCoreMLModel)  {
        do {
            let objectRecognition = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
                Task {
                    if let results = request.results {
                        await self.drawVisionRequestResults(results)
                    }
                }
            })
            objectRecognition.imageCropAndScaleOption = .scaleFill
            self.requests = [objectRecognition]
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
    }
    
    func makeObservations(pixelBuffer: CVImageBuffer) throws {
        let orientation = exifOrientationFromDeviceOrientation()
        let vnHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        guard let visionModel else { return }
        guard canPredict else { return }
        
        try vnHandler.perform(requests)
    }
    
    func drawVisionRequestResults(_ results: [Any]) async {
        rects.removeAll()
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            // Select only the label with the highest confidence.
            let topLabelObservation = objectObservation.labels[0]
            rects.append(
                RectangleData(
                    id: UUID(),
                    rect: objectObservation.boundingBox,
                    label: topLabelObservation.identifier,
                    confidence: objectObservation.confidence,
                    colour: Color.red)
            )
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
            exifOrientation = .up
        }
        return exifOrientation
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = sampleBuffer.imageBuffer else { return }

        do {
            try makeObservations(pixelBuffer: buf)
        } catch {
            print("Failed to make observations")
        }
    }
}

struct RectangleData: Identifiable {
    let id: UUID
    let rect: CGRect
    let label: String
    let confidence: Float
    let colour: Color
}
