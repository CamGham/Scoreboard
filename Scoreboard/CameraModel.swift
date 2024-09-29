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
final class CameraModel {
    
    
    var previewSource: PreviewSource { captureService.previewSource }
    let captureService = CaptureService()
    
    func start() async {
        guard await captureService.isAuthorized else {
            return
        }
        do {
            try await captureService.start()
            
        } catch {
            
        }
    }
    

    
 
    func classifyImage(img: CIImage) async throws -> String {
        let req = ClassifyImageRequest()
//        var obs: [String:Float] = [:]
        var obs: [String] = []
        
        let res = try await req.perform(on: img).filter { ob in
            ob.hasMinimumPrecision(0.1, forRecall: 0.8)
        }
        
        
        for classification in res {
            obs.append(classification.identifier)
//            obs[classification.identifier] = classification.confidence
        }
        
        
        
        return obs.first ?? "Unknown"
    }
    
    
}


class OutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        print("frame dropped")
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        print("new frame")
        do {
//            try sampleBuffer.makeDataReady()
            
            
            guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            

            let handler = ImageRequestHandler(buf)
            
            Task {
                
//                let con = DetectContoursRequest()
//                let req = try await handler.perform(con)
//                
//                print("\(req.description)")
//                path = req.normalizedPath
                
                
                let req = try await handler.perform(ClassifyImageRequest())
                
                let res = req.filter { ob in
                    ob.hasMinimumRecall(0.01, forPrecision: 0.9)
                }
               
               
                for cl in res {
                    print("\(cl.identifier) \(cl.confidence)")
                }
            }
        } catch {
            
        }
        
    }
}
