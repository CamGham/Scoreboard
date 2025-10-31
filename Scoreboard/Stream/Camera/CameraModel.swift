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
    
    // should look for new objects every 10 sec
    var shouldPredict = true
    let predictionTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()
    // can run observations every 0.05 sec to avoid over-processing
    var canObserve = true
    let observationTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    var dontCareAboutPerformance = true // override observation limit
    
    // Object detection
    var visionModel: VNCoreMLModel?
    private var requests = [VNRequest]()
    var rects: [RectangleData] = []
    
    // Track objects over multiple frames
    let seqHandler = VNSequenceRequestHandler()
    var trackingRequests = [VNRequest]()
    var trackedRects: [RectangleData] = []
    var rectangles = [UUID: RectangleData]()
    var observations = [UUID: VNDetectedObjectObservation]()
    
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
            // === Setup recognition request for objects defined by input model ===
            // pixel buffer stream camera causes a new VNImageRequestHandler to be created
            // this runs the following completionHander code that:
            //      Initiates a new array of tracking requests + UI draws on every object detected
            let objectRecognition = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
                // Clear any previous 'initial' object detections
                Task { @MainActor in
                    self.rects.removeAll()
                }
                
                // iterate through new requests
                if let results = request.results as? [VNRecognizedObjectObservation] {
                    
                    // WARNING
                    // TODO: this resets the trackingRequests array - so any long living tracks are lost
                    // Need to implement an update/merge function to map any existing requests (existing track sequences of VNTrackObjectRequest where tracked object has a confidence greater than 0.5) to new requests
                    self.trackingRequests = results.map({ objectObservation  in
                        // make request for tracking on this observation
                        let trackRequest = VNTrackObjectRequest(detectedObjectObservation: objectObservation)
                        trackRequest.trackingLevel = .accurate
                        
                        // on UI update initial bounding boxes
                        Task { @MainActor in
                            self.rects.append(
                                RectangleData(
                                    id: UUID(),
                                    rect: objectObservation.boundingBox,
                                    label: objectObservation.labels[0].identifier,
                                    confidence: objectObservation.confidence,
                                    colour: Color.red)
                                )
                        }
                        
                        return trackRequest
                    })
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

        try vnHandler.perform(requests)
    }
        
    func trackObservations(pixelBuffer: CVImageBuffer) throws {
        let orientation = exifOrientationFromDeviceOrientation()
        do {
            try seqHandler.perform(trackingRequests, on: pixelBuffer, orientation: orientation)
            
            var tempTrackedRects: [RectangleData] = []
            trackingRequests = trackingRequests.compactMap { req -> VNRequest? in
                // Only handle VNTrackObjectRequest
                guard let trackReq = req as? VNTrackObjectRequest else { return nil }
                guard let newObs = trackReq.results?.first as? VNDetectedObjectObservation else { return nil }
                
                // Drop if confidence is too low
                guard newObs.confidence > 0.3 else { return nil }
                
                tempTrackedRects.append(
                    RectangleData(
                        id: newObs.uuid,
                        rect: newObs.boundingBox,
                        label: "", // Select only the label with the highest confidence.
                        confidence: newObs.confidence,
                        colour: Color.green)
                    )
                
                // Update the input observation for continued tracking
                trackReq.inputObservation = newObs
                return trackReq
            }
            
            // Update UI with tracked object bounding boxes
            Task { @MainActor in
                self.trackedRects = tempTrackedRects
            }
            
            // fallback if we lose all tracks
            if trackingRequests.isEmpty {
                shouldPredict = true
            }
            
        } catch {
            print("Tracking failed")
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
            if shouldPredict {
                shouldPredict = false
                try makeObservations(pixelBuffer: buf)
            } else if canObserve || dontCareAboutPerformance {
                canObserve = false
                try trackObservations(pixelBuffer: buf)
            }
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
