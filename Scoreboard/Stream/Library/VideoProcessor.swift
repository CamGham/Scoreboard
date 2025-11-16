//
//  VideoProcessor.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/11/2025.
//

import Foundation
import AVKit
import SwiftUI
import UIKit

enum VideoError: Error {
    case loading
}

@Observable
class VideoProcessor {
    var currentFrame: Image?
    
    // video asset
    var videoAsset: AVAsset
    var videoTrack: AVAssetTrack
    
    // read frames
    var videoReader: AVAssetReader
    var videoAssetReaderOutput: AVAssetReaderTrackOutput
    
    var tracker = VisionTracker()
    
    private init(videoAsset: AVAsset,
                     videoTrack: AVAssetTrack,
                     videoReader: AVAssetReader,
                     videoAssetReaderOutput: AVAssetReaderTrackOutput,
                     firstFrame: Image?) {
            self.videoAsset = videoAsset
            self.videoTrack = videoTrack
            self.videoReader = videoReader
            self.videoAssetReaderOutput = videoAssetReaderOutput
            self.currentFrame = firstFrame
        }
    
    func clear() {
        tracker.clear()
    }
    
    static func create(videoAsset: AVURLAsset) async throws -> VideoProcessor {
        let _ = try await videoAsset.load(.isPlayable)
        
        let tracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw VideoError.loading
        }
        
        let metadata = try await videoAsset
        
        let videoReader = try AVAssetReader(asset: videoAsset)
        let outputSetting = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        
        
        let videoAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSetting)
        guard videoReader.canAdd(videoAssetReaderOutput) else {
            throw VideoError.loading
        }
        videoReader.add(videoAssetReaderOutput)
        videoReader.startReading()
        
        // Try to read first frame synchronously (optional)
        var firstFrame: Image? = nil
        if let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer(),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            firstFrame = CIImage(cvPixelBuffer: pixelBuffer).image
        }
        
        return VideoProcessor(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            videoReader: videoReader,
            videoAssetReaderOutput: videoAssetReaderOutput,
            firstFrame: firstFrame
        )
    }
    
    
    func startReadingFrames() -> Bool {
        guard self.videoReader.canAdd(self.videoAssetReaderOutput) else {
            return false
        }
        
        self.videoReader.add(self.videoAssetReaderOutput)
        return self.videoReader.startReading()
    }
    
    func readNextFrame() -> CVImageBuffer? {
        guard let sampleBuffer = self.videoAssetReaderOutput.copyNextSampleBuffer(),
              let buff = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        currentFrame = CIImage(cvPixelBuffer: buff).image
        return buff
    }
    
    func autoReadFrames() async {
        do {
            var frames = 1
            while true {
                guard let buf = readNextFrame() else {
                    return
                }
                frames += 1

                if tracker.shouldPredict || (frames % 300 == 0) {
                    tracker.shouldPredict = false
                    try tracker.makeObservations(pixelBuffer: buf)
                } else if frames % 3 == 0 {
                    try tracker.trackObservations(pixelBuffer: buf)
                }
            }
        } catch {
            
        }
    }
}


fileprivate extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .right)
    }
}
