//
//  SectionReanalysisTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 24/09/2026.
//

import Testing
import Foundation
import AVFoundation
import CoreImage
@testable import Scoreboard

// MARK: - Fixtures

private let mergeRim = HoopGeometry(
    center: CGPoint(x: 0.5, y: 0.70),
    verticalRadius: 0.012,
    horizontalRadius: 0.045
)

/// An attempt whose key moment — and so its place on the timeline — is `at`.
private func attempt(
    at time: Double,
    result: ShotAttempt.Result = .made,
    startFrame: Int = 0,
    verdict: ShotAttempt.UserVerdict? = nil
) -> ShotAttempt {

    let trajectory = (0..<6).map { step in
        BallObservation(
            frameID: startFrame + step,
            center: CGPoint(x: 0.4 + Double(step) * 0.02, y: 0.6),
            radius: 0.02,
            confidence: 0.9,
            timeSeconds: time - 0.2 + (Double(step) * 0.05)
        )
    }

    return ShotAttempt(
        id: UUID(),
        startFrame: startFrame,
        endFrame: startFrame + 6,
        result: result,
        trajectory: trajectory,
        crossings: [
            RimCrossing(
                frame: Double(startFrame + 4),
                x: 0.5,
                normalisedOffset: result == .made ? 0.2 : 1.1,
                isClean: result == .made,
                timeSeconds: time
            )
        ],
        rimContacts: 0,
        apexY: 0.8,
        wasDetectedLate: false,
        rim: mergeRim,
        userVerdict: verdict
    )
}

// MARK: - Merging a re-analysed window

@MainActor
struct ReanalysisMergeTests {

    @Test("A re-analysed window replaces only what was inside it")
    func mergeReplacesOnlyTheWindow() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(at: 5)))
        state.handle(.attemptResolved(attempt(at: 15)))
        state.handle(.attemptResolved(attempt(at: 45)))

        let outcome = state.replaceAttempts(in: 10...20, with: [attempt(at: 14, result: .missed)])

        #expect(outcome.removed == 1)
        #expect(outcome.added == 1)
        #expect(state.shotTimeline.map(\.keyTime) == [5, 14, 45])
    }

    @Test("A second pass that finds nothing removes what the first one claimed")
    func emptyPassClearsTheWindow() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(at: 12)))
        state.handle(.attemptResolved(attempt(at: 30)))

        let outcome = state.replaceAttempts(in: 10...20, with: [])

        #expect(outcome.removed == 1)
        #expect(outcome.added == 0)
        #expect(state.shotTimeline.count == 1)
        #expect(state.shotTimeline[0].keyTime == 30)
    }

    @Test("A pass that finds more shots than before adds them all")
    func passCanFindMoreShots() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(at: 12)))

        let outcome = state.replaceAttempts(
            in: 10...20,
            with: [attempt(at: 11), attempt(at: 14, result: .missed), attempt(at: 18)]
        )

        #expect(outcome.removed == 1)
        #expect(outcome.added == 3)
        #expect(state.stats.attempts == 3)
    }

    @Test("Merged shots land in playing order, not at the end")
    func mergedShotsAreSortedIntoPlace() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(at: 5)))
        state.handle(.attemptResolved(attempt(at: 50)))

        state.replaceAttempts(in: 20...30, with: [attempt(at: 25)])

        #expect(state.shotTimeline.map(\.keyTime) == [5, 25, 50])
    }

    @Test("Unresolved attempts in the window are replaced too")
    func abandonedAttemptsAreReplaced() {
        let state = GameState()
        state.handle(.attemptResolved(attempt(at: 12, result: .abandoned)))

        let outcome = state.replaceAttempts(in: 10...20, with: [attempt(at: 12.5, result: .made)])

        #expect(outcome.removed == 1)
        #expect(state.abandonedAttempts.isEmpty)
        #expect(state.shotTimeline.count == 1)
    }

    @Test("A ruling made before re-analysis is reapplied to the new shot")
    func rulingsSurviveReanalysis() {
        let state = GameState()
        // The user said the shot at 12s was a make; the detector had called it a miss.
        state.applyStoredTruth([GroundTruthEntry(timeSeconds: 12, verdict: .made)])
        state.handle(.attemptResolved(attempt(at: 12, result: .missed)))

        // A second pass finds the same shot a fraction later and still calls it a miss.
        state.replaceAttempts(in: 10...20, with: [attempt(at: 12.1, result: .missed)])

        #expect(state.shotTimeline.count == 1)
        #expect(state.shotTimeline[0].userVerdict == .made)
        #expect(state.stats.makes == 1)
    }

    @Test("A shot still in flight when the window ended is not merged in")
    func inProgressAttemptsAreDropped() {
        let state = GameState()

        let outcome = state.replaceAttempts(in: 10...20, with: [attempt(at: 19, result: .inProgress)])

        #expect(outcome.added == 0)
        #expect(state.reviewableAttempts.isEmpty)
    }
}

// MARK: - Frame numbering

@Test("A ranged pass's frame indices are moved onto the clip's own numbering")
func framesAreOffsetOntoTheClip() {
    let found = attempt(at: 2, startFrame: 0)

    let moved = found.offsettingFrames(by: 300)

    #expect(moved.startFrame == 300)
    #expect(moved.endFrame == 306)
    #expect(moved.trajectory.first?.frameID == 300)
    #expect(moved.crossings.first?.frame == 304)
}

@Test("Offsetting frames leaves the times alone — they were absolute already")
func offsettingKeepsTimes() {
    let found = attempt(at: 2)

    let moved = found.offsettingFrames(by: 300)

    #expect(moved.keyTime == found.keyTime)
    #expect(moved.trajectory.map(\.timeSeconds) == found.trajectory.map(\.timeSeconds))
}

// MARK: - The pass itself

/// Writes a short, plain video so the reader path can be exercised without shipping a
/// fixture. There is nothing to detect in it — this covers the plumbing: that a ranged
/// read starts where it was asked to, ends on its own, and reports progress to the end.
private func makeTestClip(seconds: Double, fps: Int32 = 30) async throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
    )
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240
        ]
    )

    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let total = Int(seconds * Double(fps))
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else { continue }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            // A flat grey field; the content is irrelevant, only the timing is.
            memset(base, 90, CVPixelBufferGetBytesPerRow(buffer) * 240)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }

    input.markAsFinished()
    await writer.finishWriting()

    return url
}

@Test("A ranged pass reads only its window, finishes on its own, and reports progress")
func rangedPassCoversOnlyItsWindow() async throws {
    let url = try await makeTestClip(seconds: 4)
    defer { try? FileManager.default.removeItem(at: url) }

    let asset = AVURLAsset(url: url)

    var reported: [Double] = []
    let attempts = try await SectionReanalyser.analyse(
        asset: asset,
        range: 1.0...2.5,
        rim: mergeRim,
        onProgress: { reported.append($0) }
    )

    // Nothing to detect in a flat grey clip, but the pass must still complete.
    #expect(attempts.isEmpty)
    #expect(reported.last == 1)
    #expect(reported.allSatisfy { $0 >= 0 && $0 <= 1 })
}

// MARK: - The pass's own tally

@Test("Collecting a pass's results doesn't silence its own shot tally")
func collectorRunsAlongsideTheTrackersOwnHandler() {
    // The bug: the collector replaced the handler feeding the tracker's GameState, so a
    // watched re-analysis showed 0/0 on screen while finding shots perfectly well.
    let found = AttemptCollector()

    var delivered = 0
    let handler = SectionReanalyser.collecting(
        into: found,
        alongside: { _ in delivered += 1 }
    )

    handler(.attemptResolved(attempt(at: 12)))
    handler(.rimContact(id: UUID()))

    #expect(found.attempts.count == 1)
    // Every event still reaches the tracker's own listener, not just resolutions.
    #expect(delivered == 2)
}

@Test("With nothing else listening, collecting still works")
func collectorHandlesNoExistingHandler() {
    let found = AttemptCollector()
    let handler = SectionReanalyser.collecting(into: found, alongside: nil)

    handler(.attemptResolved(attempt(at: 3)))

    #expect(found.attempts.count == 1)
}
