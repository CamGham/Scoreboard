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
    
    // Frame identification
    // Monotonic index of frames processed by VisionTracker, advanced by `beginFrame()`.
    // This is the single time base for the trajectory fit — it must count video frames,
    // not milliseconds, because the ballistic thresholds are expressed per frame.
    private(set) var frameCounter: Int = 0
    
    
    // Object detection
    var visionModel: VNCoreMLModel?
    var requests = [VNRequest]()
    var rects: [RectangleData] = []
    var hoop: [RectangleData] = []
    
    // Track objects over multiple frames
    var seqHandler = VNSequenceRequestHandler()
    
    var trackingRequests = [TypedTrackRequest]()
    var trackedRects: [RectangleData] = []

    /// Most recent ball sighting, drawn separately since the ball is no longer a track.
    var ballRect: RectangleData?
    
    //TODO: reID using UUID + feature similarity
//    var rectangles = [UUID: RectangleData]()
//    var observations = [UUID: VNDetectedObjectObservation]()
    
    var objectsToIgnore: [TypedTrackRequest] = []
    
    /// Main-actor game state for the UI to read.
    let gameState = GameState()

    /// Shot detection engine. Runs on the frame-processing thread; results are handed
    /// to `gameState` on the main actor.
    let shotTracker = ShotTracker()

    /// Finds the ball by re-detecting inside a moving crop each frame. The ball is no
    /// longer part of the `VNTrackObjectRequest` pool — see `BallDetector`.
    private(set) var ballDetector: BallDetector?

    /// Zones kept from before the model finished loading, which is when the ball detector
    /// is built. Without this, zones set during setup would reach the tracker but not the
    /// detector, and a decoy could still pull the moving crop onto itself.
    private var pendingExclusionZones: [ExclusionZone] = []

    init() {
        print("DEBUG: TRACKER CREATED")

        setOverlayUpdates(true)

        shotTracker.onEvent = { [gameState] event in
            Task { @MainActor in
                gameState.handle(event)
            }
        }

        Task {
            await visionModel = try ObjectDetector.createDetector()
            if let visionModel {
                setupVision(model: visionModel)
                ballDetector = BallDetector(model: visionModel)
                ballDetector?.exclusionZones = pendingExclusionZones
            }
        }
    }
    
    deinit {
        print("DEBUG: TRACKER DESTROYED")
    }
    
    /// Whether per-frame overlay snapshots are published to `gameState`.
    ///
    /// Each snapshot is a hop to the main actor, and the only thing that reads one is an
    /// overlay drawn over the frames. A pass nobody is watching has no use for them, so
    /// it turns them off — and back on if the user decides to watch after all.
    func setOverlayUpdates(_ enabled: Bool) {
        shotTracker.onSnapshot = enabled
            ? { [gameState] snapshot in
                Task { @MainActor in
                    gameState.apply(snapshot)
                }
            }
            : nil
    }

    func clear() {
        seqHandler = VNSequenceRequestHandler()
        shotTracker.endOfStream(atFrame: frameCounter)
    }

    /// Open a new video frame. Must be called exactly once per frame, before running
    /// detection or tracking on it.
    ///
    /// The frame index used to live inside `trackObservations`, which meant frames that
    /// only ran detection never advanced it — several observations would share a frame
    /// ID and collapse the trajectory fit's time axis.
    /// - Parameter timeSeconds: presentation time of this frame. Optional because the
    ///   frame index alone is enough to detect shots; the timestamp is what makes them
    ///   seekable afterwards.
    func beginFrame(timeSeconds: Double? = nil) {
        frameCounter &+= 1
        shotTracker.beginFrame(frameCounter, timeSeconds: timeSeconds)
    }

    /// Detect the ball for this frame, inside a crop around its predicted position.
    ///
    /// Must be called once per frame, after `beginFrame()`. Independent of the player
    /// tracking path — the two no longer interfere.
    func detectBall(pixelBuffer: CVImageBuffer, orientation: CGImagePropertyOrientation) {
        guard let ballDetector else { return }

        guard let found = ballDetector.detect(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            frameID: frameCounter,
            history: shotTracker.ballHistory,
            fit: shotTracker.currentFit
        ) else { return }

        shotTracker.ingestBall(
            boundingBox: found.boundingBox,
            confidence: CGFloat(found.confidence),
            frameID: frameCounter
        )

        Task { @MainActor in
            self.ballRect = RectangleData(
                id: UUID(),
                rect: found.boundingBox,
                label: "Ball",
                confidence: found.confidence,
                colour: .orange
            )
        }
    }

    /// How this tracker is currently configured, for recording with an analysis run.
    ///
    /// Assembled from the live objects rather than from defaults, so the record reflects
    /// what actually ran.
    func currentConfiguration() -> RunConfiguration {
        RunConfiguration(
            shotDetector: ShotDetectorConfig(),
            ballROI: ballDetector?.config ?? BallROIPredictor.Config(),
            fullFrameBallConfidence: Double(ballDetector?.fullFrameConfidence ?? 0.45),
            croppedBallConfidence: Double(ballDetector?.croppedConfidence ?? 0.25),
            modelIdentifier: ObjectDetector.modelIdentifier,
            rimSource: {
                guard shotTracker.rim != nil else { return .none }
                return shotTracker.isRimUserPlaced ? .userPlaced : .detected
            }()
        )
    }

    /// Pin the rim to a geometry the user placed by hand.
    func setUserRim(_ geometry: HoopGeometry) {
        shotTracker.setUserRim(geometry)
        shotTracker.refreshSnapshot(frameID: frameCounter)

        Task { @MainActor in
            self.hoop = [
                RectangleData(
                    id: UUID(),
                    rect: geometry.boundingBox,
                    label: "Rim (placed)",
                    confidence: 1.0,
                    colour: .orange)
            ]
        }
    }

    /// Blocked-out parts of the frame, applied to both the detector's candidate list and
    /// the tracker's commit point.
    func setExclusionZones(_ zones: [ExclusionZone]) {
        pendingExclusionZones = zones
        shotTracker.exclusionZones = zones
        ballDetector?.exclusionZones = zones
    }

    /// Seed the rim from a pre-flight scan of the clip.
    func seedRim(_ geometry: HoopGeometry) {
        shotTracker.seedRim(geometry)
        shotTracker.refreshSnapshot(frameID: frameCounter)
    }

    /// The model, once it has finished loading. Used by the pre-flight rim scan.
    func awaitVisionModel() async -> VNCoreMLModel? {
        for _ in 0..<50 {
            if let visionModel { return visionModel }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return visionModel
    }
    
    func setupVision(model: VNCoreMLModel) {
        
        // === Setup recognition request for objects defined by input model ===
        // pixel buffer stream camera causes a new VNImageRequestHandler to be created
        // this runs the following completionHander code every 10 sec that:
        //      Initiates a new array of tracking requests + UI draws on every object detected
        let objectRecognition = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
            
            let runFullObservation = self.shouldPredict
            if runFullObservation {
                // Clear any previous 'initial' object detections
                Task { @MainActor in
                    self.rects.removeAll()
                }
                
                self.shouldPredict = false
                
                // reset sequence handler:
                //      - can only track 6 simultanuous requests
                //      - memory consumption ramps up crazy quick when left alive for more than a few seconds
                self.seqHandler = VNSequenceRequestHandler()
            }
            
            if let results = request.results as? [VNRecognizedObjectObservation] {
                
                // Keep sampling the rim until the estimate has settled, not merely
                // until the first one lands. Detection runs on few frames, so stopping
                // at the first sighting freezes the scoring plane on one noisy box with
                // no way to recover from a bad one.
                if !self.shotTracker.isRimLocked {
                    // A lower bar than the general filter below: the rim is static, so a
                    // run of middling detections still medians into a good estimate.
                    let hoops = results.filter({
                        $0.labels.first?.identifier == "Rim"
                        &&
                        $0.confidence > 0.5
                    })
                    var temp: [TypedTrackRequest] = []
                    if !hoops.isEmpty {
                        self.createNewTrackingRequests(
                            newObservations: hoops,
                            &temp)
                    }
                }
                
                // filter minimum confidence
                var newObservations = results.filter { objDet in
                    objDet.confidence > 0.6
                }
                guard !newObservations.isEmpty else {
                    return
                }
                
                
                // we dont need to track hoop
                // but check it hasnt moved
                
//                if !self.hoop.isEmpty {
//                    newObservations = newObservations.filter({ objDet in
//                        objDet.labels.first?.identifier != "Rim"
//                    })
//                }
                
                // prepare new tracking requests (combine existing with new)
                var outputTrackingRequests = [TypedTrackRequest]()
                
                let existingTracks = self.trackingRequests
                if existingTracks.isEmpty { // make initial tracking requests
                    self.createNewTrackingRequests(
                        newObservations: newObservations,
                        &outputTrackingRequests)
                    
                    
                    // All six slots go to players now that the ball is detected by
                    // crop instead of tracked.
                    let finalTracks = Array(
                        outputTrackingRequests
                            .sorted(by: { $0.request.inputObservation.confidence > $1.request.inputObservation.confidence })
                            .prefix(6)
                    )
                    
                    self.trackingRequests = finalTracks
                    return
                }
                
                do {
                    // TODO: update matrix to work with new tracks
                    // Maybe this is cause of players being assigned as 'ball'?
                    if !newObservations.isEmpty {
                        // create cost matrix of exsitingTracks against new observations
                        
                        let vectorRows: [Vector] = existingTracks.map { trackReq in
                            return Vector(
                                newObservations.map { objectDetection in
                                    if trackReq.type.rawValue != objectDetection.labels.first!.identifier {
                                        return 1.0 // only calculate matches if the objects are the same type
                                    }
                                    
                                    let overlap = self.iou(
                                        box1: trackReq.request.inputObservation.boundingBox,
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
                            track.request.inputObservation = bestObservation
                            outputTrackingRequests.append(track)
                        }
                    }
                    
                    // if existingTracks.count > newObservations.count we will have left over tracking requests
                    // continue any remaining tracks
                    for trackReq in existingTracks{
                        if !outputTrackingRequests.contains(where:
                                                                {$0.request.inputObservation.uuid == trackReq.request.inputObservation.uuid}) {
                            outputTrackingRequests.append(trackReq)
                        }
                    }
                    
                    // if existingTracks.count < newObservations.count we will have left over new observations
                    // create new tracking from remainging observations
                    let remainingObservations = newObservations.filter { ob in
                        return !outputTrackingRequests.contains { outputReq in
                            outputReq.request.inputObservation.uuid == ob.uuid
                        }
                    }
                    
                    self.createNewTrackingRequests(newObservations: remainingObservations, &outputTrackingRequests)
                    
                    
                    
                    let finalTracks = Array(
                        outputTrackingRequests
                            .sorted(by: { $0.request.inputObservation.confidence > $1.request.inputObservation.confidence })
                            .prefix(6)
                    )
                    self.trackingRequests = finalTracks
                    
                } catch {
                    print("Error occured during tracking merge")
                }
            }
        })
        objectRecognition.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFit
        self.requests = [objectRecognition]
    }
    
    
    private func createNewTrackingRequests(newObservations: [VNRecognizedObjectObservation], _ outputTrackingRequests: inout [TypedTrackRequest]) {
        for o in newObservations {
            
            if o.labels.first?.identifier == "Rim" {
                // The rim is static, so every detection is another sample of the same
                // object rather than a replacement for it. ShotTracker takes the running
                // median so the scoring plane doesn't wobble under an in-flight shot.
                shotTracker.ingestRim(boundingBox: o.boundingBox, frameID: frameCounter)

                if let smoothed = shotTracker.rim {
                    Task { @MainActor in
                        self.hoop = [
                            RectangleData(
                                id: UUID(),
                                rect: smoothed.boundingBox,
                                label: o.labels[0].identifier,
                                confidence: o.confidence,
                                colour: Color.red)
                        ]
                    }
                }
                continue
            }
            
            // The ball is found by BallDetector's moving crop, not by visual tracking,
            // so it never enters the track pool. That frees a slot for another player
            // and stops a lost ball from churning the player track list.
            if o.labels.first?.identifier == ObjectType.ball.rawValue {
                continue
            }

            let trackType: ObjectType = .player

            let trackRequest = TypedTrackRequest(observation: o, type: trackType)
            if objectsToIgnore.contains(where: { req in
                req.request.inputObservation.boundingBox.origin.isRoughlyEqual(to: o.boundingBox.origin)
            }) {
                // dont re add an ignored object
                print("NOT ADDING DUE TO IGNORANCE")
                continue
            }
            trackRequest.request.trackingLevel = .accurate
            outputTrackingRequests.append(trackRequest)
            
            
            // on UI update initial bounding boxes
            Task { @MainActor in
                self.rects.append(
                    RectangleData(
                        id: UUID(),
                        rect: o.boundingBox,
                        label: o.labels[0].identifier,
                        confidence: o.confidence,
                        colour: Color.red.opacity(0.2))
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
                        return nil
                    }
                    
                    return trackReq
                }
                
                
                // Drop if confidence is too low
                guard newObs.confidence > 0.2 else {
                    trackReq.lowConfidenceFrames += 1
                    
                    if trackReq.lowConfidenceFrames >= 5 {
                        trackReq.request.isLastFrame = true
                        return nil
                    }
                    // feed in new observation for new request
                    trackReq.request.inputObservation = newObs
                    return trackReq
                }
               
                //Temporary: While model/tracking struggles with false positives, if an object has not moved, increase low confidnce
                if trackReq.request.inputObservation.boundingBox.origin.isRoughlyEqual(to: newObs.boundingBox.origin) {
                    print("Not moved: \(trackReq.lowConfidenceFrames)")
                    
                    trackReq.lowConfidenceFrames += 1
                    if trackReq.lowConfidenceFrames >= 3 {
                        print("Removing track")
                        trackReq.request.isLastFrame = true
                        
                        objectsToIgnore.append(trackReq)
                        
                        return nil
                    }
                } else {
                    // reset lost frame count
                    trackReq.lowConfidenceFrames = 0
                }
                
                tempTrackedRects.append(
                    RectangleData(
                        id: newObs.uuid,
                        rect: newObs.boundingBox,
                        label: "Player",
                        confidence: newObs.confidence,
                        colour: .green)
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

extension CGPoint {
    
    //Coord: (0.21090893215603299, 0.7338885625203451)
    //Coord: (0.2111816264964916, 0.7341182708740235)
    //Coord: (0.2111816264964916, 0.7341182708740235)
    //Coord: (0.21154762550636574, 0.7343326568603515)
    //Coord: (0.21154762550636574, 0.7343326568603515)
    
    // we want small changes like above to be marked essentailly as the same point
    func isRoughlyEqual(to other: CGPoint) -> Bool {
        if abs(self.x - other.x) < 0.001 && abs(self.y - other.y) < 0.001 {
            return true
        }
        return false
    }
}

