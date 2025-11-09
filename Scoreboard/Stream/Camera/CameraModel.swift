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
    var dontCareAboutPerformance = false // override observation limit
    
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
    
    func setupVision(model: VNCoreMLModel) {
        
        // === Setup recognition request for objects defined by input model ===
        // pixel buffer stream camera causes a new VNImageRequestHandler to be created
        // this runs the following completionHander code every 10 sec that:
        //      Initiates a new array of tracking requests + UI draws on every object detected
        let objectRecognition = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
            // Clear any previous 'initial' object detections
            Task { @MainActor in
                self.rects.removeAll()
            }
            
            if let results = request.results as? [VNRecognizedObjectObservation] {
                // filter minimum confidence
                let newObservations = results.filter { objDet in
                    objDet.confidence > 0.7
                }
                guard !newObservations.isEmpty else {
                    return
                }
                
                // prepare new tracking requests (combine existing with new)
                var outputTrackingRequests = [VNTrackObjectRequest]()
                
                var existingTracks = self.trackingRequests
                if existingTracks.isEmpty { // make initial tracking requests
                    self.createNewTrackingRequests(
                        newObservations: newObservations,
                        &outputTrackingRequests)
                    self.trackingRequests = outputTrackingRequests
                    return
                }
                
                do {
                    // create cost matrix of exsitingTracks against new observations
                    let vectorRows: [Vector] = existingTracks.map { trackReq in
                        return Vector(
                            newObservations.map { objectDetection in
                                let overlap = self.iou(
                                    box1: trackReq.inputObservation.boundingBox,
                                    box2: objectDetection.boundingBox
                                )
                                return 1.0 - overlap // lowest cost
                            }
                        )
                    }
                    let costMatrix: Matrix = Matrix(vectorRows)
                    
                    // find best matches using Hungarian algorithm
                    let assignments = try HungarianAlgorithm.findOptimalAssignment(costMatrix)
                    
                    // merge best new observations with existing tracks
                    for index in assignments.rowIndices.indices {
                        // get the assignment indicies
                        let trackIndex = assignments.rowIndices[index]
                        let bestObservationIndex = assignments.columnIndices[index]
                        
                        let track = existingTracks[trackIndex]
                        let bestObservation = newObservations[bestObservationIndex]
                        track.inputObservation = bestObservation
                        outputTrackingRequests.append(track)
                    }
                    
                    // if existingTracks.count > newObservations.count we will have left over tracking requests
                    // continue any remaining tracks
                    for trackReq in existingTracks{
                        if !outputTrackingRequests.contains(where:
                            {$0.inputObservation.uuid == trackReq.inputObservation.uuid}) {
                            outputTrackingRequests.append(trackReq)
                        }
                    }
                    
                    // if existingTracks.count < newObservations.count we will have left over new observationd
                    // create new tracking from remainging observations
                    let remainingObservations = newObservations.filter { ob in
                        return !outputTrackingRequests.contains { outputReq in
                            outputReq.inputObservation.uuid == ob.uuid
                        }
                    }
                    self.createNewTrackingRequests(newObservations: remainingObservations, &outputTrackingRequests)
                    
                    self.trackingRequests = outputTrackingRequests
                } catch {
                    print("Error occured during tracking merge")
                }
            }
        })
        objectRecognition.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFill
        self.requests = [objectRecognition]
    }
    
    private func createNewTrackingRequests(newObservations: [VNRecognizedObjectObservation], _ outputTrackingRequests: inout [VNTrackObjectRequest]) {
        for o in newObservations {
            // make request for tracking on this observation
            let trackRequest = VNTrackObjectRequest(detectedObjectObservation: o)
            trackRequest.trackingLevel = .accurate
            outputTrackingRequests.append(trackRequest)
            
            // on UI update initial bounding boxes
            Task { @MainActor in
                self.rects.append(
                    RectangleData(
                        id: UUID(),
                        rect: o.boundingBox,
                        label: o.labels[0].identifier,
                        confidence: o.confidence,
                        colour: Color.red)
                )
            }
        }
    }
    
    private func iou(box1: CGRect, box2: CGRect) -> Double {
        // IoU = area of overlap / area of union
        let intersectionRect = box1.intersection(box2)
        if intersectionRect.isNull || intersectionRect.width <= 0 || intersectionRect.height <= 0 {
            return 0.0
        }
        
        let intersectionArea = intersectionRect.width * intersectionRect.height
        
        let box1Area = box1.width * box1.height
        let box2Area = box2.width * box2.height
        
        let unionArea = box1Area + box2Area - intersectionArea
        
        let iou = intersectionArea / unionArea
        return iou
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
            print("current tracks: \(trackingRequests.count)")
            var tempTrackedRects: [RectangleData] = []
            trackingRequests = Array(
                trackingRequests.compactMap { trackReq in
                    // Only handle first result
                    guard let newObs = trackReq.results?.first as? VNDetectedObjectObservation else { return nil }
                    
                    
                    // Drop if confidence is too low
                    guard newObs.confidence > 0.5 else { return nil }
                    
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
                // TODO: this is temporary to avoid exceeding track req limit
                // In future the game mode will determine what objects to prioritse
                // Most cases will be ball, with first closest player from each team,
                // could be made two players
                // ---------------------------
                // Take 6 highest confidence tracks
                .sorted { (t1: VNTrackObjectRequest, t2: VNTrackObjectRequest) in
                    t1.inputObservation.confidence > t2.inputObservation.confidence
                }
                .prefix(6)
            )
            
            // Update UI with tracked object bounding boxes
            Task { @MainActor in
                self.trackedRects = tempTrackedRects
            }
            
            // fallback if we lose all tracks
            if trackingRequests.isEmpty {
                shouldPredict = true
            }
            
        } catch let error as NSError {
            
            print("Tracking failed: \(error.description)")
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
