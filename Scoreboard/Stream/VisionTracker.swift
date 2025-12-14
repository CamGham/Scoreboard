//
//  VisionTracker.swift
//  Scoreboard
//
//  Created by Cam Graham on 15/11/2025.
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
class VisionTracker {
    var shouldPredict = true
    var canObserve = true
    
    // override above prediction/observation for object specifc requiremnts
    var shouldPredictBall: Bool = true
    
    
    // Object detection
    var visionModel: VNCoreMLModel?
    var requests = [VNRequest]()
    var rects: [RectangleData] = []
    var hoop: [RectangleData] = []
    
    // Track objects over multiple frames
    var seqHandler = VNSequenceRequestHandler()
    
    var trackingRequests = [TypedTrackRequest]()
    var trackedRects: [RectangleData] = []
    
    //TODO: reID using UUID + feature similarity
//    var rectangles = [UUID: RectangleData]()
//    var observations = [UUID: VNDetectedObjectObservation]()
    
    init() {
        Task {
            await visionModel = try ObjectDetector.createDetector()
            if let visionModel {
                setupVision(model: visionModel)
            }
        }
    }
    
    func clear() {
        seqHandler = VNSequenceRequestHandler()
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
                // reset sequence handler:
                //      - can only track 6 simultanuous requests
                //      - memory consumption ramps up crazy quick when left alive for more than a few seconds
                self.seqHandler = VNSequenceRequestHandler()
                
                // TODO: maintain a copy of tracking requests that holds the object type - that way we know to research when the ball dissapears
                var existingTracks = self.trackingRequests
                if existingTracks.isEmpty { // make initial tracking requests
                    self.createNewTrackingRequests(
                        newObservations: newObservations,
                        &outputTrackingRequests)
                    
                    
                    let finalTracks = Array(
                        outputTrackingRequests
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
                    // Remove zombies
                    print("Remaining = \(outputTrackingRequests.count - finalTracks.count)")
                    outputTrackingRequests.removeAll { req in
                        finalTracks.contains { req in
                            req == req
                        }
                    }
                    print("After: \(outputTrackingRequests.count)")
                    self.trackingRequests = finalTracks
                    return
                }
                
                do {
                    if !newObservations.isEmpty {
                        // create cost matrix of exsitingTracks against new observations
                        
                        let vectorRows: [Vector] = existingTracks.map { trackReq in
                            trackReq.inputObservation.uuid
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
                    
                    
                    
                    let finalTracks = Array(
                        outputTrackingRequests
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
                    // Remove zombies
                    print("Remaining = \(outputTrackingRequests.count - finalTracks.count)")
                    outputTrackingRequests.removeAll { req in
                        finalTracks.contains { req in
                            req == req
                        }
                    }
                    print("After: \(outputTrackingRequests.count)")
                    self.trackingRequests = finalTracks
                    
                } catch {
                    print("Error occured during tracking merge")
                }
            }
        })
        objectRecognition.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFit
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
    
    
    func makeObservations(pixelBuffer: CVImageBuffer, orientation: CGImagePropertyOrientation) throws {
        let vnHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        
        try vnHandler.perform(requests)
    }
    
    
    func trackObservations(pixelBuffer: CVImageBuffer, orientation: CGImagePropertyOrientation) throws {
        do {
            try seqHandler.perform(trackingRequests.map{ $0.request }, on: pixelBuffer, orientation: orientation)
            
            var tempTrackedRects: [RectangleData] = []
            
            trackingRequests = trackingRequests.compactMap { trackReq in
                // Only handle first result
                guard let newObs = trackReq.request.results?.first as? VNDetectedObjectObservation else {
                    trackReq.lowConfidenceFrames += 1
                    
                    if trackReq.lowConfidenceFrames >= 5 {
                        trackReq.request.isLastFrame = true
                        if trackReq.type == .ball {
                            shouldPredictBall = true
                        }
                        return nil
                    }
                    
                    return trackReq
                }
                
                
                // Drop if confidence is too low
                guard newObs.confidence > 0.2 else {
                    trackReq.lowConfidenceFrames += 1
                    
                    if trackReq.lowConfidenceFrames >= 5 {
                        trackReq.request.isLastFrame = true
                        if trackReq.type == .ball {
                            shouldPredictBall = true
                        }
                        return nil
                    }
                    
                    return trackReq
                }
               
                // reset lost frame count
                trackReq.lowConfidenceFrames = 0
                tempTrackedRects.append(
                    RectangleData(
                        id: newObs.uuid,
                        rect: newObs.boundingBox,
                        label: trackReq.type == .ball ? "Ball" : "Player",
                        confidence: newObs.confidence,
                        colour: trackReq.type == .ball ? .orange : .green)
                )
                
                // Update the input observation for continued tracking
                trackReq.request.inputObservation = newObs
                
                return trackReq
            }
            
            // fallback if we lose all tracks
            if trackingRequests.isEmpty {
                shouldPredict = true
            }

            // Update UI with tracked object bounding boxes
            Task { @MainActor in
                self.trackedRects = tempTrackedRects
            }
        } catch let error as NSError {
            
            print("Tracking failed: \(error.description)")
        }
    }
}
