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

/// Why a pass is paused — which decides whether it may pick up again by itself.
enum PauseReason {
    /// The user stopped it: the pause button, Stop and save, opening the blocked-area
    /// editor. Stays paused until they carry on.
    case userInitiated

    /// The app left the screen. Resumes when it comes back.
    case systemTriggered

    /// The reader ran out of frames. Never resumes: there is nothing left to read, and
    /// another go round the loop would end the shot stream a second time.
    case endOfClip
}

/// What a pass should do when the app moves into or out of the foreground.
enum ScenePause {
    enum Action: Equatable {
        case pause
        case resume
        case none
    }

    /// - Parameter isActive: whether the app is the active, on-screen app. Anything else —
    ///   Control Center, the app switcher, another app, the phone locked — counts as away.
    static func action(isActive: Bool, playback: PlaybackState, reason: PauseReason?) -> Action {
        if isActive {
            // Only a pause the app made itself is undone. A pass the user paused before
            // leaving is still paused when they get back.
            return playback == .pause && reason == .systemTriggered ? .resume : .none
        }
        // Already paused keeps its reason: leaving the app mustn't turn the user's pause
        // into one that resumes on return.
        return playback == .resume ? .pause : .none
    }
}

@Observable
class VideoProcessor {
    var currentFrame: Image?
    var playback = PlaybackState.pause

    /// Why the pass is paused. Nil while it runs, and before it has started. Set through
    /// `pause(_:)` and cleared by `resume()`.
    private(set) var pauseReason: PauseReason?

    /// Guards `isLooping`, and the loop's decision to stop — see `play()`.
    @ObservationIgnored private let loopLock = NSLock()

    /// Whether a frame loop is running. Only touched under `loopLock`.
    @ObservationIgnored private var isLooping = false

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

    /// The part of the clip being read — nil for all of it. Kept so a rebuilt reader stops
    /// where the original would have.
    private let readRange: CMTimeRange?

    /// Exact presentation time of the last frame handed out, for starting a new reader
    /// just after it. Nil when that frame had no valid timestamp, or before any frame.
    @ObservationIgnored private var lastPresentationTime: CMTime?

    /// Whether any frame has been handed out. Tells "nothing read yet" — start again from
    /// the top — apart from "read, but untimed", which can't be picked up again.
    @ObservationIgnored private var hasReadFrame = false

    /// After a rebuild, frames up to and including this time have been analysed already.
    @ObservationIgnored private var skipThrough: CMTime?

    /// Rebuilds since a frame last came through.
    @ObservationIgnored private var consecutiveRebuilds = 0

    /// A real interruption recovers on the first rebuild. A reader that dies again straight
    /// after every one is broken in a way a new reader won't fix.
    static let maxConsecutiveRebuilds = 3

    /// Why reading stopped for good, once it has. Nil while reading, and after a clip that
    /// simply ran to its end.
    private(set) var readFailure: (any Error)?
    
    // helpers
    var preferredTransform: CGAffineTransform
    var orientation: CGImagePropertyOrientation
    var trackSize: CGSize
    
    var tracker: VisionTracker

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
                 readRange: CMTimeRange?,
                 firstFrame: Image?,
                 preferredTransform: CGAffineTransform,
                 orientation: CGImagePropertyOrientation,
                 trackSize: CGSize,
                 nominalFrameRate: Float,
                 producesPreviewFrames: Bool,
                 configuration: RunConfiguration) {
        print("DEBUG: PROCESSER CREATED")
            self.tracker = VisionTracker(configuration: configuration)
            self.videoAsset = videoAsset
            self.videoTrack = videoTrack
            self.videoReader = videoReader
            self.videoAssetReaderOutput = videoAssetReaderOutput
            self.readRange = readRange
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
    ///   - configuration: settings for every part of the tracker.
    ///   - resumingAfter: the last frame a saved pass analysed. Reading starts on the frame
    ///     after it, as if the pass had never stopped. For the whole clip only, not a
    ///     section.
    static func create(
        videoAsset: AVAsset,
        timeRange: CMTimeRange? = nil,
        producesPreviewFrames: Bool = true,
        configuration: RunConfiguration = RunConfiguration(),
        resumingAfter resumeTime: CMTime? = nil
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
        let videoAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        guard videoReader.canAdd(videoAssetReaderOutput) else {
            throw VideoError.loading
        }
        videoReader.add(videoAssetReaderOutput)

        // Must be set before reading starts. A resumed pass starts at the frame it last
        // analysed; `prepareToResume(after:)` skips that one.
        if let resumeTime {
            videoReader.timeRange = CMTimeRange(start: resumeTime, duration: .positiveInfinity)
        } else if let timeRange {
            videoReader.timeRange = timeRange
        }

        videoReader.startReading()
        
        var firstFrame: Image? = nil
        if producesPreviewFrames, let resumeTime {
            // Not from the reader: a frame taken from it for the poster is never analysed,
            // and on a resumed pass that would leave a gap right where it picks up.
            firstFrame = await Self.still(of: videoAsset, at: resumeTime)
        } else if producesPreviewFrames,
           let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer(),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            firstFrame = ciImage.oriented(orientation).image
        }
        
        let processor = VideoProcessor(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            videoReader: videoReader,
            videoAssetReaderOutput: videoAssetReaderOutput,
            readRange: timeRange,
            firstFrame: firstFrame,
            preferredTransform: preferredTransform,
            orientation: orientation,
            trackSize: trackSize,
            nominalFrameRate: frameRate,
            producesPreviewFrames: producesPreviewFrames,
            configuration: configuration
        )
        if let resumeTime { processor.prepareToResume(after: resumeTime) }
        return processor
    }

    /// One frame of `asset` at `time`, turned the right way up, for a poster.
    private static func still(of asset: AVAsset, at time: CMTime) async -> Image? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    /// Carry on a saved pass: the frame at `time` was the last one analysed, so it and
    /// anything before it the reader hands back is skipped — the same rule as a rebuilt
    /// reader.
    private func prepareToResume(after time: CMTime) {
        lastPresentationTime = time
        hasReadFrame = true
        skipThrough = time
        currentFrameTime = time.seconds
        analysedTime = time.seconds
    }

    /// Exact time of the last frame analysed, for saving where a pass got to. Nil before
    /// any frame, or when that frame had no timestamp.
    var lastFrameTime: CMTime? { lastPresentationTime }

    /// Whether a frame loop is running right now. Pausing lets the frame in hand finish,
    /// so this can stay true for a moment after `pause(_:)`.
    var isLoopRunning: Bool { loopLock.withLock { isLooping } }

    /// Frames as Vision wants them: biplanar YCbCr, which the appearance sampler also reads.
    /// Shared by the first reader and any rebuilt one, so a rebuilt pass sees the same
    /// pixels.
    static var outputSettings: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    }

    /// Whether a reader that stopped with `error` is worth replacing with a new one.
    ///
    /// Only for being cut off — the app going to the background, or iOS restarting its
    /// media services. A file or decoder that is actually broken fails again at the same
    /// place, however many readers are built.
    static func isRecoverable(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError?, error.domain == AVFoundationErrorDomain else {
            return false
        }
        switch AVError.Code(rawValue: error.code) {
        case .operationInterrupted, .mediaServicesWereReset:
            return true
        default:
            return false
        }
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
        // Loops only to step past a reader that was rebuilt, or the frames a rebuilt reader
        // hands back that were already analysed.
        while true {
            let sample = PipelineSignpost.measure("Decode") {
                videoAssetReaderOutput.copyNextSampleBuffer()
            }

            guard let sampleBuffer = sample,
                  let buff = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                // A nil sample means either the end of the clip or a reader that gave up.
                // Only the former counts as a finished analysis; the status lags the last
                // sample by a moment, so `.reading` here still means it ran to the end.
                switch videoReader.status {
                case .failed, .cancelled:
                    // Cut off rather than broken: carry on from a new reader as if
                    // nothing happened.
                    if videoReader.status == .failed, rebuildReaderIfRecoverable() { continue }

                    // Paused with no reason, so nothing resumes it: a stopped reader
                    // can't be read again.
                    readFailure = videoReader.error ?? VideoError.loading
                    loopLock.withLock { playback = .pause }
                default:
                    pause(.endOfClip)
                    isComplete = true
                }

                return nil
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // A rebuilt reader starts from the keyframe before where it was asked to, so its
            // first frames can be ones already analysed. Analysing one twice would tick the
            // frame counter with the ball standing still.
            if let skipThrough {
                if presentationTime.isValid, CMTimeCompare(presentationTime, skipThrough) <= 0 {
                    CMSampleBufferInvalidate(sampleBuffer)
                    continue
                }
                self.skipThrough = nil
            }

            consecutiveRebuilds = 0
            hasReadFrame = true
            lastPresentationTime = presentationTime.isValid ? presentationTime : nil

            return handOut(sampleBuffer, buff, at: presentationTime)
        }
    }

    /// Records a frame's time, draws its preview if anyone is watching, and returns its
    /// pixels for analysis.
    private func handOut(
        _ sampleBuffer: CMSampleBuffer,
        _ buff: CVImageBuffer,
        at presentationTime: CMTime
    ) -> CVImageBuffer {
        currentFrameTime = presentationTime.isValid ? presentationTime.seconds : nil

        if let time = currentFrameTime,
           time - analysedTime >= Self.progressInterval || time < analysedTime {
            analysedTime = time
        }

        if producesPreviewFrames {
            PipelineSignpost.measure("Preview") {
                let ciImage = CIImage(cvPixelBuffer: buff)
                currentFrame = ciImage.oriented(orientation).image
            }
        }

        CMSampleBufferInvalidate(sampleBuffer)
        return buff
    }

    /// Replace a reader that was cut off, if this one is worth replacing — see
    /// `isRecoverable(_:)` and `maxConsecutiveRebuilds`.
    private func rebuildReaderIfRecoverable() -> Bool {
        guard Self.isRecoverable(videoReader.error),
              consecutiveRebuilds < Self.maxConsecutiveRebuilds else { return false }

        consecutiveRebuilds += 1
        return rebuildReader()
    }

    /// Start a new reader just after the last frame handed out, and read on from it.
    ///
    /// The tracker, and everything it has learnt, carries on untouched: as far as it can
    /// tell, the next frame simply follows the last one. False when there is nowhere
    /// exact to pick up from, or the new reader won't start.
    ///
    /// Internal rather than private so tests can rebuild part-way through a clip.
    func rebuildReader() -> Bool {
        let start: CMTime
        if let lastPresentationTime {
            start = lastPresentationTime
        } else if !hasReadFrame {
            // Nothing analysed yet: start again from the top.
            start = readRange?.start ?? .zero
        } else {
            // The last frame had no timestamp, so there's no telling where it was.
            return false
        }

        guard let reader = try? AVAssetReader(asset: videoAsset) else { return false }

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: Self.outputSettings)
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        // Must be set before reading starts. A ranged pass stops where it always would.
        reader.timeRange = readRange.map { CMTimeRange(start: start, end: $0.end) }
            ?? CMTimeRange(start: start, duration: .positiveInfinity)

        guard reader.startReading() else { return false }

        videoReader = reader
        videoAssetReaderOutput = output
        skipThrough = lastPresentationTime
        return true
    }

    /// Hold the pass, saying why.
    func pause(_ reason: PauseReason) {
        loopLock.withLock {
            playback = .pause
            pauseReason = reason
        }
    }

    /// Let the pass carry on. Only flips the flag: a loop still finishing its last frame
    /// picks it up, otherwise the caller starts one with `play()`.
    func resume() {
        loopLock.withLock {
            playback = .resume
            pauseReason = nil
        }
    }

    /// Analyse frames until paused or out of frames.
    ///
    /// Only one loop ever runs. Pausing lets the current frame finish, so a quick pause
    /// and resume — Control Center pulled down and let go — can call this while the last
    /// loop is still mid-frame. Two loops would pull from one reader into one tracker,
    /// which isn't safe, so a call made while a loop is running returns at once.
    func play() async {
        guard claimLoop() else { return }

        while continueLoop() {
            autoreleasepool {
                PipelineSignpost.measure("Frame") {
                    guard let buf = readNextFrame() else {
                        tracker.clear()
                        return
                    }
                    frames += 1
                    tracker.beginFrame(timeSeconds: currentFrameTime)

                    // The ball gets a detection pass every frame, inside a crop around its
                    // predicted position; the players get one every few frames on the same
                    // handler, and are carried forward on their predictions in between.
                    tracker.detect(pixelBuffer: buf, orientation: orientation)

                    onFrameProcessed?(currentFrameTime)
                }
            }
        }
    }

    /// Takes the frame loop, or returns false when one is already running.
    private func claimLoop() -> Bool {
        loopLock.withLock {
            guard !isLooping else { return false }
            isLooping = true
            return true
        }
    }

    /// Whether the loop should take another frame.
    ///
    /// Gives the loop up in the same locked step as deciding to stop, so a resume landing
    /// at that moment either keeps this loop going or finds it gone and starts a new one —
    /// never both, and never neither.
    private func continueLoop() -> Bool {
        loopLock.withLock {
            if playback == .resume { return true }
            isLooping = false
            return false
        }
    }

}


fileprivate extension CIImage {
    /// Shared by every preview frame. Building a context sets up a GPU device and its
    /// caches, which cost about as much as a model pass when it was done per frame.
    /// `CIContext` is thread-safe, so one instance serves every processor.
    ///
    /// Intermediates aren't cached because no two video frames are alike — keeping them
    /// would only hold memory.
    static let previewContext = CIContext(options: [.cacheIntermediates: false])

    var image: Image? {
        guard let cgImage = Self.previewContext.createCGImage(self, from: self.extent) else { return nil }
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
