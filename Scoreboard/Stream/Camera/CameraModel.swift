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
    
    var bufferSize: CGSize = .zero
    var rects: [RectangleData] = []
    var rectangles = [UUID: RectangleData]()
    var observations = [UUID: VNDetectedObjectObservation]()
    var visionModel: VNCoreMLModel?
    
    var gameState = GameState()

 
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
    
    let sequenceHandler = VNSequenceRequestHandler()
    var startingOb: VNDetectedObjectObservation?
    let requestHandler = VNSequenceRequestHandler()
    
    func makeObservations(pixelBuffer: CVImageBuffer) async {
        Task {
            let orientation = exifOrientationFromDeviceOrientation()
            let vnHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

            guard let visionModel else { return }
            guard canPredict else { return }
            
            Task { @MainActor in
                canPredict = false
            }
            previewSource.updateLayer()
            /// search for new objects every x frames/seconds
            if self.rects.isEmpty {
                let objectDetc = VNCoreMLRequest(model: visionModel) { vnReq, error in
                    if let results = vnReq.results {
                        print("found \(results.count)")
                        self.drawVisionRequestResults(results)
//                        if let ball = self.drawVisionRequestResults(results) {
//                            self.startingOb = VNRecognizedObjectObservation(boundingBox: ball.boundingBox)
//                        }
                    }
                }
                
                do {
                    try vnHandler.perform([objectDetc])
                } catch {
                    print("object detection failed")
                }
                
            }
            
            // track observed objects every frame
            
            
        }
        
        
        Task {
            guard !self.observations.isEmpty else {
                return
            }
            var rects = [RectangleData]()
            var trackingRequests = [VNRequest]()
            let orientation = exifOrientationFromDeviceOrientation()
            for inputOb in self.observations {
                var request = VNTrackObjectRequest(detectedObjectObservation: inputOb.value)
                request.trackingLevel = .accurate
                trackingRequests.append(request)
            }
            
            do {
                try requestHandler.perform(trackingRequests, on: pixelBuffer, orientation: orientation)
                
            } catch {
                print("tracking failed")
            }
            
            for processedRequest in trackingRequests {
//                print("tacking for \(processedRequest)")
                guard let results = processedRequest.results else {
                    print("failed")
                    continue
                }
                
                guard let observation = results.first as? VNDetectedObjectObservation else {
                    print("failed")
                    continue
                }
                
                guard var previousRect = rectangles[observation.uuid] else {
                    print("Lost a rect")
                    continue
                }
                
                guard observation.confidence > 0.5 else {
                    continue
                }
                
                rects.append(RectangleData(id: observation.uuid, rect: VNImageRectForNormalizedRect(observation.boundingBox, Int(bufferSize.width), Int(bufferSize.height)), label: previousRect.label, confidence: observation.confidence, colour: previousRect.colour))
                self.observations[observation.uuid] = observation
            }
            
            Task { @MainActor in
                self.rects = rects
            }
        }
        
    }
    
    
    func drawVisionRequestResults(_ results: [Any]) {
        var tempRects: [RectangleData] = []
        
        let observations = results.compactMap { observation in
            observation as? VNRecognizedObjectObservation
        }
        
        
        // assume one ball
        let ball = observations.filter { ob in
            ob.labels.first?.identifier == "ball"
        }.first
        
        let players = observations.filter { ob in
            ob.labels.first?.identifier == "person"
        }
        
        // make func
        var potentailPlayersWithBall = [VNRecognizedObjectObservation]()
        for player in players {
            if let ball, ball.boundingBox.intersects(player.boundingBox) {
                potentailPlayersWithBall.append(player)
            }
        }
        
        
        potentailPlayersWithBall.forEach { player in
            tempRects.append(RectangleData(id: player.uuid, rect: VNImageRectForNormalizedRect(player.boundingBox, Int(bufferSize.width), Int(bufferSize.height)), label: player.labels[0].identifier, confidence: player.confidence, colour: .green))
        }
        
        if let ball {
            var inputObservation = VNDetectedObjectObservation(boundingBox: ball.boundingBox)
            let request = VNTrackObjectRequest(detectedObjectObservation: inputObservation)
            tempRects.append(RectangleData(id: ball.uuid, rect: VNImageRectForNormalizedRect(ball.boundingBox, Int(bufferSize.width), Int(bufferSize.height)), label: ball.labels[0].identifier, confidence: ball.confidence, colour: potentailPlayersWithBall.isEmpty ? .red : .green))
            
            
        }
        
        let restOfPlayers = players.filter { p in
            !potentailPlayersWithBall.contains(p)
        }
        
        tempRects.append(contentsOf: restOfPlayers.map({ ob in
            RectangleData(id: ob.uuid, rect: VNImageRectForNormalizedRect(ob.boundingBox, Int(bufferSize.width), Int(bufferSize.height)), label: ob.labels[0].identifier, confidence: ob.confidence, colour: .red)
        }))
        
        
        for rect in tempRects {
            let inputObservation = VNDetectedObjectObservation(boundingBox: rect.rect)
            self.observations[inputObservation.uuid] = inputObservation
            self.rectangles[inputObservation.uuid] = rect
        }
        

        
//        Task { @MainActor in
//            rects = tempRects
//        }
        
        
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
    let id: UUID
    let rect: CGRect
    let label: String
    let confidence: Float
    let colour: Color
}
