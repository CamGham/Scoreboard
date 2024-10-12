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

@Observable
final class CameraModel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var previewSource: PreviewSource { captureService.previewSource }
    let captureService = CaptureService()
    
    var myLabel = ""
    var canPredict = false
    let predictionTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

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
            
        }
    }
    
    func makeObservations(pixelBuffer: CVImageBuffer) async {
        guard canPredict else { return }
        
        Task { @MainActor in
            canPredict = false
        }
    
        Task {
            let handler = ImageRequestHandler(pixelBuffer)
            let req = try await handler.perform(ClassifyImageRequest())
            
            let res = req.filter { ob in
                ob.hasMinimumRecall(0.01, forPrecision: 0.9)
            }
            
            Task { @MainActor in
                myLabel = res.first?.identifier ?? "Unknown"
            }
        }
    }
    
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = sampleBuffer.imageBuffer else { return }

        Task {
            await makeObservations(pixelBuffer: buf)
        }
    }
}
