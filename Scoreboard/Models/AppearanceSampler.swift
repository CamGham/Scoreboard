//
//  AppearanceSampler.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/10/2026.
//

import Foundation
import CoreVideo
import ImageIO

/// What one player looked like on one frame.
struct AppearanceSample: Equatable {
    /// A colour histogram for each `AppearanceSampler.Band`, in band order. Each sums to 1,
    /// or is all zeros when none of the band fell inside the frame.
    var bands: [[Float]]

    /// The box's height and the height of its bottom edge — the feet — in Vision
    /// normalized space.
    var height: CGFloat
    var footY: CGFloat

    /// Width over height, in normalized units. A rough reading of build.
    var aspect: CGFloat

    /// The box's horizontal centre, in Vision normalized space: where across the court
    /// they were, and so what was behind them.
    var centreX: CGFloat = 0.5
}

/// Reads a player's colours out of a frame, band by band down their box.
///
/// Frames arrive as YCbCr: a full-size brightness plane and a half-size colour plane.
/// Colour is read straight from those, with no conversion of the frame. Each box is read
/// at a fixed grid of points rather than every pixel, so a player near the camera costs
/// no more than one far away.
struct AppearanceSampler {

    struct Config: Codable, Equatable {
        /// Points read across and down each box.
        var columns = 16
        var rows = 48

        /// Where each band ends, as a fraction of the box's height from the top, in
        /// `Band` order — a rough body layout for someone standing upright.
        var bandBottoms: [CGFloat] = [0.12, 0.45, 0.62, 0.90, 1]

        /// Share of the box's width read in each band, centred. Narrower than the box to
        /// keep out what's either side; wider at the feet, which spread apart.
        var bandWidths: [CGFloat] = [0.6, 0.6, 0.6, 0.6, 0.8]

        /// Below this brightness a pixel is black whatever its colour: very dark pixels
        /// carry almost no colour, and what there is is noise.
        var darkLuma: UInt8 = 24

        /// Colour strength below which a pixel counts as colourless, and above which it
        /// counts as vivid. Distances from the neutral point of the colour plane.
        var colourlessRadius: Float = 12
        var vividRadius: Float = 40

        /// Brightness at which a colourless pixel stops being black and becomes grey, and
        /// stops being grey and becomes white.
        var greyFromLuma: UInt8 = 80
        var whiteFromLuma: UInt8 = 180
    }

    /// Horizontal slices of a player's box, top to bottom.
    enum Band: Int, CaseIterable {
        case head, torso, shorts, legs, feet
    }

    /// Three colourless bins — black, grey, white — then 12 hues at two strengths. Fixed
    /// rather than configured: every saved look is laid out this way.
    static let binCount = 3 + hueSectors * 2

    private static let hueSectors = 12

    let config: Config

    /// Bin for every (Cb, Cr) pair, or `colourless` when the colour is too weak to have a
    /// reliable hue. Built once per sampler: an angle per pixel would otherwise be the
    /// most expensive thing here.
    private let chromaTable: [UInt8]

    init(config: Config = Config()) {
        self.config = config
        self.chromaTable = Self.chromaTable(for: config)
    }

    /// Each box's appearance on this frame, in the order given. Nil if the frame isn't
    /// 8-bit bi-planar YCbCr.
    ///
    /// - Parameter boxes: in Vision normalized space, relative to the frame as displayed
    ///   — the same space as the detections.
    func samples(
        of boxes: [CGRect],
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [AppearanceSample]? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else { return nil }

        guard !boxes.isEmpty else { return [] }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }

        let planes = Planes(
            luma: lumaBase.assumingMemoryBound(to: UInt8.self),
            lumaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            chroma: chromaBase.assumingMemoryBound(to: UInt8.self),
            chromaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        )

        return boxes.map { sample(box: $0, planes: planes, orientation: orientation) }
    }

    /// Which histogram bin a pixel's colour falls in.
    func bin(luma: UInt8, cb: UInt8, cr: UInt8) -> Int {
        guard luma >= config.darkLuma else { return 0 }

        let chroma = chromaTable[Int(cb) << 8 | Int(cr)]
        guard chroma == Self.colourless else { return Int(chroma) }

        if luma < config.greyFromLuma { return 0 }
        if luma < config.whiteFromLuma { return 1 }
        return 2
    }

    // MARK: Reading

    private struct Planes {
        let luma: UnsafePointer<UInt8>
        let lumaStride: Int
        let chroma: UnsafePointer<UInt8>
        let chromaStride: Int
        let width: Int
        let height: Int
    }

    private func sample(
        box: CGRect,
        planes: Planes,
        orientation: CGImagePropertyOrientation
    ) -> AppearanceSample {
        let bandCount = Band.allCases.count
        var bands = [[Float]](repeating: [Float](repeating: 0, count: Self.binCount), count: bandCount)
        var counts = [Float](repeating: 0, count: bandCount)

        for row in 0..<config.rows {
            let down = (CGFloat(row) + 0.5) / CGFloat(config.rows)
            let band = config.bandBottoms.firstIndex { down < $0 } ?? bandCount - 1
            let width = band < config.bandWidths.count ? config.bandWidths[band] : 0.6

            for column in 0..<config.columns {
                let across = 0.5 + ((CGFloat(column) + 0.5) / CGFloat(config.columns) - 0.5) * width

                // Vision space has its origin bottom-left, so the top of the box is maxY.
                let displayX = box.minX + across * box.width
                let displayY = 1 - (box.maxY - down * box.height)
                let (x, y) = Self.bufferPoint(displayX: displayX, displayY: displayY, orientation: orientation)

                guard x >= 0, x < 1, y >= 0, y < 1 else { continue }

                let px = Int(x * CGFloat(planes.width))
                let py = Int(y * CGFloat(planes.height))
                let luma = planes.luma[py * planes.lumaStride + px]
                let chroma = (py / 2) * planes.chromaStride + (px / 2) * 2
                let cb = planes.chroma[chroma]
                let cr = planes.chroma[chroma + 1]

                let slot = min(band, bandCount - 1)
                bands[slot][bin(luma: luma, cb: cb, cr: cr)] += 1
                counts[slot] += 1
            }
        }

        for index in bands.indices where counts[index] > 0 {
            bands[index] = bands[index].map { $0 / counts[index] }
        }

        return AppearanceSample(
            bands: bands,
            height: box.height,
            footY: box.minY,
            aspect: box.height > 0 ? box.width / box.height : 0,
            centreX: box.midX
        )
    }

    /// A point in the frame as displayed (origin top-left, normalized) to the same point
    /// in the buffer as stored. Vision's orientation names how the stored image must be
    /// turned to display upright: `.right` is a quarter turn clockwise.
    static func bufferPoint(
        displayX x: CGFloat,
        displayY y: CGFloat,
        orientation: CGImagePropertyOrientation
    ) -> (x: CGFloat, y: CGFloat) {
        switch orientation {
        case .down: (1 - x, 1 - y)
        case .right: (y, 1 - x)
        case .left: (1 - y, x)
        default: (x, y)
        }
    }

    // MARK: Colour bins

    private static let colourless: UInt8 = .max

    private static func chromaTable(for config: Config) -> [UInt8] {
        var table = [UInt8](repeating: colourless, count: 256 * 256)
        for cb in 0..<256 {
            for cr in 0..<256 {
                let u = Float(cb) - 128
                let v = Float(cr) - 128
                let radius = hypot(u, v)
                guard radius >= config.colourlessRadius else { continue }

                let turn = (atan2(v, u) + .pi) / (2 * .pi)
                let sector = min(Int(turn * Float(hueSectors)), hueSectors - 1)
                let vivid = radius >= config.vividRadius ? 1 : 0
                table[cb << 8 | cr] = UInt8(3 + sector * 2 + vivid)
            }
        }
        return table
    }
}

extension AppearanceSampler.Config {
    // Lenient, so settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        columns = try container.decode(.columns, or: defaults.columns)
        rows = try container.decode(.rows, or: defaults.rows)
        bandBottoms = try container.decode(.bandBottoms, or: defaults.bandBottoms)
        bandWidths = try container.decode(.bandWidths, or: defaults.bandWidths)
        darkLuma = try container.decode(.darkLuma, or: defaults.darkLuma)
        colourlessRadius = try container.decode(.colourlessRadius, or: defaults.colourlessRadius)
        vividRadius = try container.decode(.vividRadius, or: defaults.vividRadius)
        greyFromLuma = try container.decode(.greyFromLuma, or: defaults.greyFromLuma)
        whiteFromLuma = try container.decode(.whiteFromLuma, or: defaults.whiteFromLuma)
    }
}
