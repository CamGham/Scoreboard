//
//  LenientDecoding.swift
//  Scoreboard
//
//  Created by Cam Graham on 23/10/2026.
//

import Foundation

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it isn't there — a setting saved before it
    /// existed. A value that is there but malformed still throws.
    func decode<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
