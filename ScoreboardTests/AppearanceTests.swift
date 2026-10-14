//
//  AppearanceTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 11/10/2026.
//

import Testing
import Foundation
import CoreVideo
@testable import Scoreboard

private typealias YCbCr = (luma: UInt8, cb: UInt8, cr: UInt8)

private let blue: YCbCr = (80, 200, 100)
private let white: YCbCr = (235, 128, 128)
private let black: YCbCr = (30, 128, 128)

/// A bi-planar YCbCr frame, coloured pixel by pixel in stored (not displayed) layout.
private func frame(width: Int, height: Int, colour: (Int, Int) -> YCbCr) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &created
    )
    let buffer = created!

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

    for y in 0..<height {
        for x in 0..<width {
            luma[y * lumaStride + x] = colour(x, y).luma
        }
    }
    for y in 0..<height / 2 {
        for x in 0..<width / 2 {
            let pixel = colour(x * 2, y * 2)
            chroma[y * chromaStride + x * 2] = pixel.cb
            chroma[y * chromaStride + x * 2 + 1] = pixel.cr
        }
    }

    return buffer
}

private func share(of colour: YCbCr, in histogram: [Float]) -> Float {
    histogram[AppearanceSampler.bin(luma: colour.luma, cb: colour.cb, cr: colour.cr)]
}

private func band(_ band: AppearanceSampler.Band, of sample: AppearanceSample) -> [Float] {
    sample.bands[band.rawValue]
}

// MARK: - Reading colour

@Test("Colour at the bottom of a box is read into the feet band")
func feetColourIsRead() throws {
    // Black above three quarters of the way down, blue below.
    let buffer = frame(width: 64, height: 128) { _, y in y >= 96 ? blue : black }

    // Covers rows 16 to 112, so its bottom tenth is all blue.
    let box = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75)
    let sample = try #require(AppearanceSampler.samples(of: [box], in: buffer, orientation: .up)?.first)

    #expect(share(of: blue, in: band(.feet, of: sample)) == 1)
    #expect(share(of: blue, in: band(.head, of: sample)) == 0)
    #expect(share(of: black, in: band(.torso, of: sample)) == 1)
}

@Test("A frame stored on its side is read the right way up")
func rotatedFrameIsRead() throws {
    // Stored landscape, displayed portrait after a quarter turn clockwise: the right of
    // the stored frame is the bottom of the picture.
    let buffer = frame(width: 128, height: 64) { x, _ in x >= 116 ? blue : black }
    let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    let turned = try #require(AppearanceSampler.samples(of: [whole], in: buffer, orientation: .right)?.first)
    #expect(share(of: blue, in: band(.feet, of: turned)) == 1)
    #expect(share(of: blue, in: band(.head, of: turned)) == 0)

    let unturned = try #require(AppearanceSampler.samples(of: [whole], in: buffer, orientation: .up)?.first)
    #expect(share(of: blue, in: band(.feet, of: unturned)) < 0.2)
}

@Test("Very dark pixels count as black whatever their colour")
func darkPixelsAreBlack() {
    #expect(AppearanceSampler.bin(luma: 15, cb: 170, cr: 100) == 0)
    #expect(AppearanceSampler.bin(luma: 60, cb: 128, cr: 130) == 0)
    #expect(AppearanceSampler.bin(luma: 235, cb: 128, cr: 128) == 2)
    #expect(AppearanceSampler.bin(luma: 80, cb: 200, cr: 100) >= 3)
}

@Test("Navy and black land in different bins")
func navyIsNotBlack() {
    let navy = AppearanceSampler.bin(luma: 45, cb: 150, cr: 120)
    let black = AppearanceSampler.bin(luma: 30, cb: 128, cr: 128)
    #expect(navy != black)
}

@Test("A frame in another pixel format isn't read")
func otherFormatIsSkipped() {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &created)
    let samples = AppearanceSampler.samples(
        of: [CGRect(x: 0, y: 0, width: 1, height: 1)],
        in: created!,
        orientation: .up
    )
    #expect(samples == nil)
}

// MARK: - Measuring separation

/// A sample whose bands are each a single colour.
private func look(
    torso: YCbCr = black,
    feet: YCbCr,
    height: CGFloat = 0.3,
    footY: CGFloat = 0.2,
    aspect: CGFloat = 0.35
) -> AppearanceSample {
    func solid(_ colour: YCbCr) -> [Float] {
        var histogram = [Float](repeating: 0, count: AppearanceSampler.binCount)
        histogram[AppearanceSampler.bin(luma: colour.luma, cb: colour.cb, cr: colour.cr)] = 1
        return histogram
    }
    return AppearanceSample(
        bands: [solid(black), solid(torso), solid(black), solid(black), solid(feet)],
        height: height,
        footY: footY,
        aspect: aspect
    )
}

private func player(_ id: Int, at x: CGFloat, seen: Int, confidence: Float = 0.9) -> PlayerTrack {
    PlayerTrack(
        id: id,
        box: CGRect(x: x - 0.04, y: 0.2, width: 0.08, height: 0.3),
        velocity: .zero,
        state: seen > 0 ? .confirmed : .coasting,
        confidence: confidence,
        firstFrame: 0,
        lastSeenFrame: seen,
        hits: 2
    )
}

@Test("Different shoes tell two players apart where matching shirts can't")
func shoesSeparateMatchingShirts() {
    var meter = AppearanceSeparation()
    for frame in 1...10 {
        meter.update(
            frameID: frame,
            tracks: [player(1, at: 0.3, seen: frame), player(2, at: 0.7, seen: frame)],
            samples: [1: look(feet: blue), 2: look(feet: white)]
        )
    }

    let summary = meter.summary
    #expect(summary.comparisons > 0)
    #expect(summary.score(for: .feet).accuracy == 1)
    #expect(summary.score(for: .torso).accuracy == 0.5)
    #expect(summary.combined.accuracy == 1)
}

@Test("Height is judged for where on court a player is, so a tall player far away still reads tall")
func heightAllowsForPerspective() {
    var meter = AppearanceSeparation()

    // Further up the frame is further from the camera, where everyone looks smaller.
    func usual(at footY: CGFloat) -> CGFloat { 0.4 - 0.5 * footY }

    for frame in 1...80 {
        let phase = CGFloat(frame % 20) / 20
        let tallFoot = 0.1 + 0.4 * phase
        let shortFoot = 0.5 - 0.4 * phase

        meter.update(
            frameID: frame,
            tracks: [player(1, at: 0.3, seen: frame), player(2, at: 0.7, seen: frame)],
            samples: [
                1: look(feet: white, height: 1.15 * usual(at: tallFoot), footY: tallFoot),
                2: look(feet: white, height: usual(at: shortFoot), footY: shortFoot),
            ]
        )
    }

    let height = meter.summary.score(for: .height)
    #expect(height.compared > 0)
    #expect(height.accuracy > 0.95)
}

@Test("Players touching end their tracklets, so the next samples aren't compared at once")
func touchingEndsTracklets() {
    var meter = AppearanceSeparation()
    let apart = { (frame: Int) in [player(1, at: 0.3, seen: frame), player(2, at: 0.7, seen: frame)] }
    let samples = [1: look(feet: blue), 2: look(feet: white)]

    for frame in 1...5 {
        meter.update(frameID: frame, tracks: apart(frame), samples: samples)
    }
    let before = meter.summary.comparisons

    meter.update(frameID: 6, tracks: [player(1, at: 0.48, seen: 6), player(2, at: 0.52, seen: 6)], samples: [:])
    for frame in 7...9 {
        meter.update(frameID: frame, tracks: apart(frame), samples: samples)
    }

    #expect(before > 0)
    #expect(meter.summary.comparisons == before)
}

@Test("Only players matched on this frame, confident, and clear of everyone are sampled")
func cleanTracksRule() {
    let frame = 10
    let clear = player(1, at: 0.1, seen: frame)
    let coasting = player(2, at: 0.3, seen: 7)
    let unsure = player(3, at: 0.5, seen: frame, confidence: 0.4)
    let touchingA = player(4, at: 0.8, seen: frame)
    let touchingB = player(5, at: 0.86, seen: frame)

    let clean = AppearanceSeparation.cleanTracks([clear, coasting, unsure, touchingA, touchingB], at: frame)

    #expect(clean.map(\.id) == [1])
}

@Test("Tracking stats saved before appearance was measured still load")
func trackingSummaryWithoutAppearanceLoads() throws {
    let json = #"{"config":{"detectionInterval":3,"highConfidence":0.6,"lowConfidence":0.25,"minimumOverlap":0.3,"passesToConfirm":2,"maxCoastFrames":30},"tracksConfirmed":27,"confirmedTrackFrames":900}"#

    let decoded = try JSONDecoder().decode(
        PlayerDetectionStats.TrackingSummary.self,
        from: Data(json.utf8)
    )
    #expect(decoded.appearance == nil)
}

@Test("Appearance numbers survive a save and load")
func appearanceSummaryRoundTrip() throws {
    var meter = AppearanceSeparation()
    for frame in 1...6 {
        meter.update(
            frameID: frame,
            tracks: [player(1, at: 0.3, seen: frame), player(2, at: 0.7, seen: frame)],
            samples: [1: look(feet: blue), 2: look(feet: white)]
        )
    }

    let decoded = try JSONDecoder().decode(
        AppearanceSeparation.Summary.self,
        from: JSONEncoder().encode(meter.summary)
    )
    #expect(decoded == meter.summary)
}

// MARK: - Weighting

/// Two players who differ only in their shoes, apart for frames 1–20.
private func meterTrainedOnShoes(frames: ClosedRange<Int> = 1...20) -> AppearanceSeparation {
    var meter = AppearanceSeparation()
    for frame in frames {
        meter.update(
            frameID: frame,
            tracks: [player(1, at: 0.3, seen: frame), player(2, at: 0.7, seen: frame)],
            samples: [1: look(feet: blue), 2: look(feet: white)]
        )
    }
    return meter
}

private func average(of sample: AppearanceSample) -> AppearanceSeparation.Look {
    var look = AppearanceSeparation.Look()
    look.add(sample, heightRatio: nil)
    return look
}

@Test("A cue's weight is its log-odds of picking the right player")
func weightIsLogOdds() {
    func weight(_ accuracy: Double) -> Double {
        AppearanceSeparation.weight(for: AppearanceSeparation.Score(correct: accuracy * 100, compared: 100))
    }

    #expect(weight(0.5) == 0)
    #expect(weight(0.4) == 0)
    #expect(abs(weight(0.99) - log(99)) < 1e-9)
    #expect(abs(weight(1) - log(0.995 / 0.005)) < 1e-9)
}

@Test("A cue that never told the players apart adds nothing when looks are compared")
func coinFlipCueCountsForNothing() throws {
    let meter = meterTrainedOnShoes()

    // Shirts never differed between the players, so they scored 50%.
    let blackShirt = average(of: look(torso: black, feet: blue))
    let whiteShirt = average(of: look(torso: white, feet: blue))
    let whiteShoes = average(of: look(torso: black, feet: white))

    #expect(meter.summary.score(for: .torso).accuracy == 0.5)
    #expect(try #require(meter.distance(blackShirt, whiteShirt)) == 0)
    #expect(try #require(meter.distance(blackShirt, whiteShoes)) > 0)
}

@Test("Until a cue has been compared enough, every cue counts the same")
func unweightedUntilJudged() throws {
    let meter = meterTrainedOnShoes(frames: 1...4)

    let blackShirt = average(of: look(torso: black, feet: blue))
    let whiteShirt = average(of: look(torso: white, feet: blue))

    #expect(try #require(meter.distance(blackShirt, whiteShirt)) > 0)
}
