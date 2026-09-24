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

    /// True once the reader has run out of frames — the whole clip has been analysed.
    ///
    /// Distinct from `playback == .pause`, which is also true whenever the user simply
    /// stopped. Only this says the analysis is finished and its results are final, which
    /// is what the review view waits on.
    var isComplete = false
    
    // video asset
    var videoAsset: AVAsset
    var videoTrack: AVAssetTrack
    
    // read frames
    var videoReader: AVAssetReader
    var videoAssetReaderOutput: AVAssetReaderTrackOutput
    var frames = 1
    
    // helpers
    var preferredTransform: CGAffineTransform
    var orientation: CGImagePropertyOrientation
    var trackSize: CGSize
    
    var tracker = VisionTracker()

    /// Frames the track claims to run at. Only an approximation on variable-frame-rate
    /// footage, so it is used for estimates — never for timing.
    var nominalFrameRate: Float = 30

    /// Whether each decoded frame is turned into a `currentFrame` image.
    ///
    /// Decoding to a `CGImage`, and the redraw it triggers, costs more than the detection
    /// itself. A pass nobody is watching — a re-analysis, or a first pass the user chose
    /// not to watch — turns this off and keeps the CPU for the work.
    ///
    /// A `var` so the choice can be changed mid-pass: switching to and from watching is
    /// just a matter of whether the next frame is drawn.
    var producesPreviewFrames: Bool

    /// Media time reached, republished a few times a second rather than every frame.
    ///
    /// `currentFrameTime` moves on every frame, so a progress view reading it would
    /// redraw thirty times a second — exactly the cost that not watching is meant to
    /// avoid. This is the same number, coarsened to what a progress bar can show.
    private(set) var analysedTime: Double = 0

    /// How much media time passes between progress updates.
    private static let progressInterval: Double = 0.25

    /// Called after each frame is analysed, with its presentation time. Lets a caller
    /// report progress without polling across threads.
    var onFrameProcessed: ((Double?) -> Void)?

    private init(videoAsset: AVAsset,
                 videoTrack: AVAssetTrack,
                 videoReader: AVAssetReader,
                 videoAssetReaderOutput: AVAssetReaderTrackOutput,
                 firstFrame: Image?,
                 preferredTransform: CGAffineTransform,
                 orientation: CGImagePropertyOrientation,
                 trackSize: CGSize,
                 nominalFrameRate: Float,
                 producesPreviewFrames: Bool) {
        print("DEBUG: PROCESSER CREATED")
            self.videoAsset = videoAsset
            self.videoTrack = videoTrack
            self.videoReader = videoReader
            self.videoAssetReaderOutput = videoAssetReaderOutput
            self.currentFrame = firstFrame
            self.preferredTransform = preferredTransform
            self.orientation = orientation
            self.trackSize = trackSize
            self.nominalFrameRate = nominalFrameRate
            self.producesPreviewFrames = producesPreviewFrames
        }
    
    deinit {
        tracker.clear()
        print("DEBUG: PROCESSER DESTROYED")
    }
    
    func clear() {
        tracker.clear()
    }

    /// Track size after the preferred transform is applied — the shape Vision analysed,
    /// and the shape an overlay has to be laid out against.
    var orientedVideoSize: CGSize {
        VideoLayout.orientedSize(trackSize, orientation: orientation)
    }
    
    /// - Parameters:
    ///   - timeRange: restricts the reader to part of the clip. Used to analyse a single
    ///     marked section rather than the whole video.
    ///   - producesPreviewFrames: false skips decoding each frame to an image, for a pass
    ///     nobody is watching.
    static func create(
        videoAsset: AVAsset,
        timeRange: CMTimeRange? = nil,
        producesPreviewFrames: Bool = true
    ) async throws -> VideoProcessor {
        let _ = try await videoAsset.load(.isPlayable)
        
        let tracks = try await videoAsset.loadTracks(withMediaType: .video)
        
        guard let videoTrack = tracks.first else {
            throw VideoError.loading
        }
        
        let trackSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 30

        // Read from the transform, not from a decoded frame — a ranged pass may not want
        // to spend a frame on a preview it will never show.
        let orientation = Self.orientation(from: preferredTransform)
        
        let videoReader = try AVAssetReader(asset: videoAsset)
        let outputSetting = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        
        
        let videoAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSetting)
        guard videoReader.canAdd(videoAssetReaderOutput) else {
            throw VideoError.loading
        }
        videoReader.add(videoAssetReaderOutput)

        // Must be set before reading starts.
        if let timeRange { videoReader.timeRange = timeRange }

        videoReader.startReading()
        
        var firstFrame: Image? = nil
        if producesPreviewFrames,
           let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer(),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            firstFrame = ciImage.oriented(orientation).image
        }
        
        return VideoProcessor(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            videoReader: videoReader,
            videoAssetReaderOutput: videoAssetReaderOutput,
            firstFrame: firstFrame,
            preferredTransform: preferredTransform,
            orientation: orientation,
            trackSize: trackSize,
            nominalFrameRate: frameRate,
            producesPreviewFrames: producesPreviewFrames
        )
    }

    /// The orientation a track's preferred transform describes.
    static func orientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
    
    
    func startReadingFrames() -> Bool {
        guard self.videoReader.canAdd(self.videoAssetReaderOutput) else {
            return false
        }
        
        self.videoReader.add(self.videoAssetReaderOutput)
        return self.videoReader.startReading()
    }
    
    /// Presentation time of the frame most recently returned by `readNextFrame()`.
    ///
    /// Read from the sample buffer before it is invalidated. Without this there is no
    /// way back from a detected shot to a position in the file: the frame index can't be
    /// converted to a time on variable-frame-rate footage, which phone video often is.
    private(set) var currentFrameTime: Double?

    func readNextFrame() -> CVImageBuffer? {
        guard let sampleBuffer = self.videoAssetReaderOutput.copyNextSampleBuffer(),
              let buff = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            playback = .pause

            // A nil sample means either the end of the clip or a reader that gave up.
            // Only the former counts as a finished analysis; the status lags the last
            // sample by a moment, so `.reading` here still means it ran to the end.
            switch videoReader.status {
            case .failed, .cancelled:
                break
            default:
                isComplete = true
            }

            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        currentFrameTime = presentationTime.isValid ? presentationTime.seconds : nil

        if let time = currentFrameTime,
           time - analysedTime >= Self.progressInterval || time < analysedTime {
            analysedTime = time
        }

        if producesPreviewFrames {
            let ciImage = CIImage(cvPixelBuffer: buff)
            currentFrame = ciImage.oriented(orientation).image
        }

        CMSampleBufferInvalidate(sampleBuffer)
        return buff
    }
    
    func play() async {
        do {
            while playback == .resume {
                try autoreleasepool {
                    guard let buf = readNextFrame() else {
                        tracker.clear()
                        return
                    }
                    frames += 1
                    tracker.beginFrame(timeSeconds: currentFrameTime)

                    // The ball gets its own detection pass every frame, inside a crop
                    // around its predicted position. Players keep the full-frame detect
                    // plus track path on their existing cadence.
                    tracker.detectBall(pixelBuffer: buf, orientation: orientation)

                    if tracker.shouldPredict {
                        try tracker.makeObservations(pixelBuffer: buf, orientation: orientation)
                    } else {
                        try tracker.trackObservations(pixelBuffer: buf, orientation: orientation)
                    }

                    onFrameProcessed?(currentFrameTime)
                }
            }
        } catch {
            
        }
    }
    
    func next() async {
        do {
            try autoreleasepool {
                guard let buf = readNextFrame() else {
                    tracker.clear()
                    return
                }
                frames += 1
                tracker.beginFrame(timeSeconds: currentFrameTime)

                // The ball gets its own detection pass every frame, inside a crop
                // around its predicted position. Players keep the full-frame detect
                // plus track path on their existing cadence.
                tracker.detectBall(pixelBuffer: buf, orientation: orientation)

                if tracker.shouldPredict {
                    try tracker.makeObservations(pixelBuffer: buf, orientation: orientation)
                } else {
                    try tracker.trackObservations(pixelBuffer: buf, orientation: orientation)
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
