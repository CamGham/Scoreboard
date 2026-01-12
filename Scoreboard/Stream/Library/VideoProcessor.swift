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

enum PlaybackState {
    case pause
    case resume
}

@Observable
class VideoProcessor {
    var currentFrame: Image?
    var playback = PlaybackState.pause
    
    // video asset
    var videoAsset: AVAsset
    var videoTrack: AVAssetTrack
    
    // read frames
    var videoReader: AVAssetReader
    var videoAssetReaderOutput: AVAssetReaderTrackOutput
    var frames = 1
    
    // helpers
    var preferredTransform: CGAffineTransform
    var trackSize: CGSize
    
    var tracker = VisionTracker()
    
    private init(videoAsset: AVAsset,
                 videoTrack: AVAssetTrack,
                 videoReader: AVAssetReader,
                 videoAssetReaderOutput: AVAssetReaderTrackOutput,
                 firstFrame: Image?,
                 preferredTransform: CGAffineTransform,
                 trackSize: CGSize) {
            self.videoAsset = videoAsset
            self.videoTrack = videoTrack
            self.videoReader = videoReader
            self.videoAssetReaderOutput = videoAssetReaderOutput
            self.currentFrame = firstFrame
            self.preferredTransform = preferredTransform
            self.trackSize = trackSize
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
        
        let trackSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        
        let videoReader = try AVAssetReader(asset: videoAsset)
        let outputSetting = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        
        
        let videoAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSetting)
        guard videoReader.canAdd(videoAssetReaderOutput) else {
            throw VideoError.loading
        }
        videoReader.add(videoAssetReaderOutput)
        videoReader.startReading()
        
        var firstFrame: Image? = nil
        if let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer(),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            let rotated = ciImage.transformed(by: preferredTransform)
            let flipped = rotated.transformed(by: CGAffineTransform(scaleX: -1, y: -1))
            let corrected = flipped.transformed(by:
                CGAffineTransform(translationX: 0, y: -flipped.extent.height)
            )
            firstFrame = corrected.image   
        }
        
        return VideoProcessor(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            videoReader: videoReader,
            videoAssetReaderOutput: videoAssetReaderOutput,
            firstFrame: firstFrame,
            preferredTransform: preferredTransform,
            trackSize: trackSize
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
            playback = .pause
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: buff)
        
        let rotated = ciImage.transformed(by: preferredTransform)
        let flipped = rotated.transformed(by: CGAffineTransform(scaleX: -1, y: -1)) // neg x for makes portrait work
        let corrected = flipped.transformed(by:
            CGAffineTransform(translationX: 0, y: -flipped.extent.height)
        )
        currentFrame = corrected.image
        
        CMSampleBufferInvalidate(sampleBuffer)
        return buff
    }
    
    func play() async {
        do {
            while playback == .resume {
                try autoreleasepool {
                    guard let buf = readNextFrame() else { return }
                    frames += 1
                    
                    if tracker.shouldPredict || (frames % 10 == 0) {
                        tracker.shouldPredict = true
                        try tracker.makeObservations(pixelBuffer: buf, orientation: .right)
                    } else {
                        
                        try tracker.trackObservations(pixelBuffer: buf, orientation: .right)
                    
                        if !tracker.shouldPredict && tracker.shouldPredictBall {
                            try tracker.makeObservations(pixelBuffer: buf, orientation: .right)
                        }
                    }
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
        return Image(decorative: cgImage, scale: 1)
    }
}

fileprivate extension CGImagePropertyOrientation {
    func toImageOrientation() -> Image.Orientation {
        switch self {
        case .up:
                .up
        case .upMirrored:
                .upMirrored
        case .down:
                .down
        case .downMirrored:
                .downMirrored
        case .leftMirrored:
                .leftMirrored
        case .right:
                .right
        case .rightMirrored:
                .rightMirrored
        case .left:
                .left
        }
    }
}
