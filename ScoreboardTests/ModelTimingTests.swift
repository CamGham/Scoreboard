//
//  ModelTimingTests.swift
//  ScoreboardTests
//
//  Created by Cam Graham on 04/10/2026.
//

import Testing
import Foundation
import CoreML
import CoreVideo
import Vision
import VideoToolbox
@testable import Scoreboard

// Where the ~15 ms of a detection pass goes.
//
// Every pass in the pipeline — ball, probe, re-detect — costs about the same in the
// signposts, which makes the pass itself the thing worth understanding. These cases
// split it apart: the bare model on each compute unit, then the same model behind
// Vision, varied one thing at a time (request reuse, crop, source size and format).
// The gap between "Core ML" and "Vision" rows is Vision's own work. The "VT" rows are
// the alternative: the hardware scaler prepares the model's input, and Core ML is called
// directly with no Vision in between.
//
// Prints a table rather than asserting: the numbers are for reading, and any threshold
// would only encode one device on one day. Search the log for "TIMING".
//
// Device only. The simulator has no Neural Engine, so its numbers say nothing about a
// phone. Run with the phone cool and unlocked — a warm phone throttles, and the thermal
// state is printed either side so a throttled run can be spotted.

private let isPhysicalDevice: Bool = {
    #if targetEnvironment(simulator)
    return false
    #else
    return true
    #endif
}()

@Suite("Model timing", .serialized, .enabled(if: isPhysicalDevice, "Needs a real device's Neural Engine"))
struct ModelTimingTests {

    @Test("Detection pass breakdown")
    func detectionPassBreakdown() async throws {
        var rows: [TimingRow] = []
        let thermalBefore = ProcessInfo.processInfo.thermalState

        // MARK: Bare model

        let modelInput = makeBGRAFrame(width: 640, height: 640)
        var allUnitsModel: best5sRefined?

        for (name, units) in [
            ("all units", MLComputeUnits.all),
            ("CPU + Neural Engine", .cpuAndNeuralEngine),
            ("CPU + GPU", .cpuAndGPU),
            ("CPU only", .cpuOnly),
        ] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units

            let loadStart = ContinuousClock.now
            let model = try best5sRefined(configuration: configuration)
            let load = (ContinuousClock.now - loadStart).milliseconds
            if units == .all { allUnitsModel = model }

            let input = best5sRefinedInput(image: modelInput, iouThreshold: 0.45, confidenceThreshold: 0.25)

            // CPU only is slow enough that fewer runs still give a steady median.
            rows.append(try measure(
                "Core ML · \(name)",
                iterations: units == .cpuOnly ? 15 : 60,
                note: String(format: "load %.0f ms", load)
            ) {
                _ = try model.prediction(input: input)
            })
        }

        // MARK: Behind Vision

        // The model exactly as the app builds it.
        let visionModel = try await ObjectDetector.createDetector()

        let frame1080 = makeVideoFrame(width: 1920, height: 1080)
        let frame4K = makeVideoFrame(width: 3840, height: 2160)

        // A ball-sized crop, square in pixels on a 16:9 frame — what BallDetector asks for.
        let ballCrop = CGRect(x: 0.4, y: 0.35, width: 0.17, height: 0.3)

        rows.append(try measure("Vision · as app · 1080p") {
            try perform(newRequest(visionModel), on: frame1080)
        })

        rows.append(try measure("Vision · as app · 4K") {
            try perform(newRequest(visionModel), on: frame4K)
        })

        let reused = newRequest(visionModel)
        rows.append(try measure("Vision · reused request · 1080p") {
            try perform(reused, on: frame1080)
        })

        let reusedCrop = newRequest(visionModel)
        reusedCrop.regionOfInterest = ballCrop
        rows.append(try measure("Vision · reused · 1080p ball crop") {
            try perform(reusedCrop, on: frame1080)
        })

        // Already the model's size and format: no scaling, no YUV conversion.
        rows.append(try measure("Vision · reused · 640² BGRA") {
            try perform(reused, on: modelInput)
        })

        // A probe frame does a cropped ball pass and a full-frame player pass. Can one
        // handler share the frame between them, or is it two passes either way?
        let pairFull = newRequest(visionModel)
        let pairCrop = newRequest(visionModel)
        pairCrop.regionOfInterest = ballCrop

        rows.append(try measure("Vision · crop + full, two handlers") {
            try perform(pairCrop, on: frame1080)
            try perform(pairFull, on: frame1080)
        })

        rows.append(try measure("Vision · crop + full, one handler") {
            let handler = VNImageRequestHandler(cvPixelBuffer: frame1080, orientation: .up)
            try handler.perform([pairCrop, pairFull])
            #expect(pairCrop.results != nil && pairFull.results != nil)
        })

        // MARK: Hardware scaler + Core ML, no Vision

        let model = try #require(allUnitsModel)

        let preparer = try FramePreparer()

        rows.append(try measure("VT prep only · 1080p → 640²") {
            _ = try preparer.prepare(frame1080)
        })

        rows.append(try measure("VT prep only · 4K → 640²") {
            _ = try preparer.prepare(frame4K)
        })

        rows.append(try measure("VT + Core ML · 1080p") {
            try predict(model, on: preparer.prepare(frame1080))
        })

        rows.append(try measure("VT + Core ML · 4K") {
            try predict(model, on: preparer.prepare(frame4K))
        })

        rows.append(try measure("VT + Core ML · 1080p ball crop") {
            try predict(model, on: preparer.prepare(frame1080, crop: ballCrop))
        })

        // The probe frame again: with no handler to share, it is simply two passes.
        rows.append(try measure("VT + Core ML · crop + full") {
            try predict(model, on: preparer.prepare(frame1080, crop: ballCrop))
            try predict(model, on: preparer.prepare(frame1080))
        })

        report(rows, thermalBefore: thermalBefore, thermalAfter: ProcessInfo.processInfo.thermalState)
    }

    private func predict(_ model: best5sRefined, on input: CVPixelBuffer) throws {
        let output = try model.prediction(
            input: best5sRefinedInput(image: input, iouThreshold: 0.45, confidenceThreshold: 0.25)
        )
        // Touch the output so the result is actually materialised, as decoding would.
        #expect(output.coordinates.shape.count == 2)
    }

    // MARK: - Helpers

    private func newRequest(_ model: VNCoreMLModel) -> VNCoreMLRequest {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        return request
    }

    private func perform(_ request: VNCoreMLRequest, on frame: CVPixelBuffer) throws {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        try handler.perform([request])
        #expect(request.results != nil)
    }
}

// MARK: - Frame preparation

/// The hardware-scaler path only means anything if it feeds the model the same picture
/// Vision would. The crop is the risky part — the scaler works from the top-left in
/// pixels, Vision from the bottom-left in fractions — so check it lands where it should.
/// Runs anywhere: the scaler works on the simulator too.
@Suite("Frame preparation")
struct FramePreparationTests {

    /// A 1920×1080 frame is black except for a white square here: square in pixels, and
    /// low enough that its top-to-bottom mirror image doesn't overlap it.
    private let square = CGRect(x: 0.6, y: 0.05, width: 0.25, height: 0.25 * 16 / 9)

    @Test("A crop takes the region Vision means, not its mirror image")
    func cropLandsOnRegion() throws {
        let frame = makeVideoFrame(width: 1920, height: 1080, whiteSquare: square)
        let prepared = try FramePreparer().prepare(frame, crop: square)

        // The crop is square in pixels, so it fills the whole input. Sampled a little
        // way in from each corner, clear of any resampling at the edges.
        for (x, y) in [(16, 16), (624, 16), (16, 624), (624, 624), (320, 320)] {
            #expect(brightness(of: prepared, x: x, y: y) > 200, "(\(x), \(y)) should be inside the square")
        }
    }

    @Test("A crop beside the square comes out black")
    func cropElsewhereMissesRegion() throws {
        let frame = makeVideoFrame(width: 1920, height: 1080, whiteSquare: square)

        // Mirrored top-to-bottom: where a crop would land with the y axis the wrong way up.
        let mirrored = CGRect(x: square.minX, y: 1 - square.maxY, width: square.width, height: square.height)
        let prepared = try FramePreparer().prepare(frame, crop: mirrored)

        #expect(brightness(of: prepared, x: 320, y: 320) < 50)
    }

    @Test("A full 16:9 frame is letterboxed, not stretched")
    func fullFrameIsLetterboxed() throws {
        let frame = makeVideoFrame(width: 1920, height: 1080, whiteSquare: CGRect(x: 0, y: 0, width: 1, height: 1))
        let prepared = try FramePreparer().prepare(frame)

        // 16:9 into a square leaves 140 rows of padding above and below.
        #expect(brightness(of: prepared, x: 320, y: 60) < 50)
        #expect(brightness(of: prepared, x: 320, y: 320) > 200)
        #expect(brightness(of: prepared, x: 320, y: 580) < 50)
    }

    @Test("Cropping leaves the frame as it found it")
    func cropIsRemovedAfterwards() throws {
        let frame = makeVideoFrame(width: 1920, height: 1080, whiteSquare: square)
        _ = try FramePreparer().prepare(frame, crop: square)

        // The same frame goes on to the full-frame pass, which must see all of it.
        #expect(CVBufferCopyAttachment(frame, kCVImageBufferCleanApertureKey, nil) == nil)
    }

    private func brightness(of buffer: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let pixel = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(pixels[pixel]) + Int(pixels[pixel + 1]) + Int(pixels[pixel + 2])) / 3
    }
}

// MARK: - Measuring

private struct TimingRow {
    let name: String
    let median: Double
    let p90: Double
    let mean: Double
    let iterations: Int
    let note: String
}

private func measure(
    _ name: String,
    warmUp: Int = 5,
    iterations: Int = 60,
    note: String = "",
    _ body: () throws -> Void
) throws -> TimingRow {
    // The first runs pay for lazy setup — compiling for the device, allocating buffers —
    // which is a one-off, not the steady per-frame cost being measured.
    for _ in 0..<warmUp { try body() }

    var samples: [Double] = []
    samples.reserveCapacity(iterations)

    for _ in 0..<iterations {
        let start = ContinuousClock.now
        try body()
        samples.append((ContinuousClock.now - start).milliseconds)
    }

    samples.sort()
    return TimingRow(
        name: name,
        median: samples[samples.count / 2],
        p90: samples[min(samples.count - 1, Int(Double(samples.count) * 0.9))],
        mean: samples.reduce(0, +) / Double(samples.count),
        iterations: iterations,
        note: note
    )
}

private func report(
    _ rows: [TimingRow],
    thermalBefore: ProcessInfo.ThermalState,
    thermalAfter: ProcessInfo.ThermalState
) {
    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    func ms(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return String(repeating: " ", count: max(0, 8 - text.count)) + text
    }

    var lines = [
        "TIMING thermal state before: \(thermalBefore.label), after: \(thermalAfter.label)",
        "TIMING \(pad("case", 38)) median      p90     mean   runs",
    ]
    for row in rows {
        lines.append(
            "TIMING \(pad(row.name, 38))\(ms(row.median))\(ms(row.p90))\(ms(row.mean))   \(row.iterations)  \(row.note)"
        )
    }
    print(lines.joined(separator: "\n"))
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}

private extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Hardware scaler

/// Turns a video frame into the model's input — 640² BGRA, letterboxed like Vision's
/// `.scaleFit` — in one hardware pass: crop, scale and colour conversion together.
///
/// The destination is reused: prediction is synchronous, so it is free again by the
/// time the next frame is prepared.
private final class FramePreparer {
    private let session: VTPixelTransferSession
    private let destination: CVPixelBuffer

    init() throws {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw FramePreparerError.status(status) }

        // Letterbox keeps the aspect ratio and pads the rest, which is what `.scaleFit`
        // does. Stretching would distort the ball into an ellipse.
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Letterbox
        )

        self.session = session
        self.destination = makePixelBuffer(width: 640, height: 640, format: kCVPixelFormatType_32BGRA)
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// - Parameter crop: region in Vision normalized space (origin bottom-left), or nil
    ///   for the whole frame.
    func prepare(_ source: CVPixelBuffer, crop: CGRect? = nil) throws -> CVPixelBuffer {
        // The scaler has no crop setting of its own. It honours the source's clean
        // aperture instead, so the crop is attached to the frame for this one transfer.
        if let crop {
            CVBufferSetAttachment(
                source,
                kCVImageBufferCleanApertureKey,
                cleanAperture(for: crop, in: source),
                .shouldNotPropagate
            )
        }
        defer {
            if crop != nil { CVBufferRemoveAttachment(source, kCVImageBufferCleanApertureKey) }
        }

        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else { throw FramePreparerError.status(status) }
        return destination
    }

    /// A clean aperture is a size plus the offset of its centre from the frame's centre,
    /// in pixels, with y running down — unlike Vision, whose origin is bottom-left.
    private func cleanAperture(for normalized: CGRect, in source: CVPixelBuffer) -> CFDictionary {
        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))

        return [
            kCVImageBufferCleanApertureWidthKey: normalized.width * width,
            kCVImageBufferCleanApertureHeightKey: normalized.height * height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: (normalized.midX - 0.5) * width,
            kCVImageBufferCleanApertureVerticalOffsetKey: (0.5 - normalized.midY) * height,
        ] as CFDictionary
    }
}

private enum FramePreparerError: Error {
    case status(OSStatus)
}

// MARK: - Frames

/// A frame in the reader's format — bi-planar YUV, IOSurface-backed like the buffers
/// `AVAssetReader` hands out, so Vision takes the same conversion path it does in the app.
///
/// - Parameter whiteSquare: draws black with this region (Vision normalized space) white,
///   instead of the default gradient.
private func makeVideoFrame(width: Int, height: Int, whiteSquare: CGRect? = nil) -> CVPixelBuffer {
    let buffer = makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    // A smooth gradient rather than noise: the model then finds next to nothing, so
    // box filtering stays as cheap as it is on a typical frame.
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for y in 0..<height {
        for x in 0..<width {
            if let whiteSquare {
                // Rows run top-down in memory; Vision's y runs bottom-up.
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: 1 - (CGFloat(y) + 0.5) / CGFloat(height)
                )
                luma[y * lumaStride + x] = whiteSquare.contains(point) ? 255 : 0
            } else {
                luma[y * lumaStride + x] = UInt8((x + y) * 255 / (width + height))
            }
        }
    }

    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    memset(chroma, 128, chromaStride * CVPixelBufferGetHeightOfPlane(buffer, 1))

    // Phone video is tagged BT.709. Without the tag a converter has to guess the matrix,
    // and may take a slower path doing so.
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

    return buffer
}

/// A frame already in the model's input format.
private func makeBGRAFrame(width: Int, height: Int) -> CVPixelBuffer {
    let buffer = makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let shade = UInt8((x + y) * 255 / (width + height))
            let pixel = y * stride + x * 4
            pixels[pixel] = shade
            pixels[pixel + 1] = shade
            pixels[pixel + 2] = shade
            pixels[pixel + 3] = 255
        }
    }

    return buffer
}

private func makePixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, format, attributes, &buffer)
    precondition(status == kCVReturnSuccess && buffer != nil, "Couldn't create a \(width)×\(height) buffer")
    return buffer!
}
