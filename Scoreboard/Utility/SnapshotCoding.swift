//
//  SnapshotCoding.swift
//  Scoreboard
//
//  Created by Cam Graham on 05/11/2026.
//

import Foundation

/// How a snapshot of a pass in progress is written and read back.
///
/// The pipeline's state can hold numbers JSON has no way to write — an infinite
/// prediction, a fit error that came out as not-a-number. The default encoder throws on
/// those, and one such number would lose the whole snapshot, so they are written as
/// strings instead. Writing and reading must agree on that, hence one place for both.
enum SnapshotCoding {
    private static let positiveInfinity = "inf"
    private static let negativeInfinity = "-inf"
    private static let notANumber = "nan"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: positiveInfinity,
            negativeInfinity: negativeInfinity,
            nan: notANumber
        )
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: positiveInfinity,
            negativeInfinity: negativeInfinity,
            nan: notANumber
        )
        return decoder
    }
}
