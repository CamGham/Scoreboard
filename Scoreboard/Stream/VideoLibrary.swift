//
//  VideoLibrary.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation
import Photos
import AVFoundation

/// Resolves a stored photo-library identifier back to a playable asset.
///
/// Saved analysis keys off `PHAsset.localIdentifier` because the file URL a picker hands
/// over is a throwaway copy. Getting the video back later therefore means going through
/// the library — which, unlike the picker itself, needs the user's permission.
enum VideoLibrary {

    enum LookupFailure: Error, Equatable {
        /// The user hasn't granted access, so nothing can be resolved.
        case notAuthorized
        /// Authorized, but the video is gone — deleted, or on another device.
        case assetMissing
    }

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Fetch the video behind a saved identifier.
    static func asset(for localIdentifier: String) async throws -> AVAsset {
        var status = authorizationStatus
        if status == .notDetermined {
            status = await requestAuthorization()
        }

        guard status == .authorized || status == .limited else {
            throw LookupFailure.notAuthorized
        }

        let results = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = results.firstObject else {
            throw LookupFailure.assetMissing
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        // The original may only exist in iCloud; allow it to be pulled down.
        options.isNetworkAccessAllowed = true

        let asset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }

        guard let asset else { throw LookupFailure.assetMissing }
        return asset
    }

    // MARK: Recording dates

    /// When a video was recorded.
    ///
    /// Photos' own date comes first: it's the one the user sees there, and they can
    /// correct it. Without library access the file's metadata stands in — the picker's
    /// copy keeps it, and reading it needs no permission.
    static func captureDate(for localIdentifier: String, asset: AVAsset) async -> Date? {
        if let date = captureDates(for: [localIdentifier])[localIdentifier] {
            return date
        }

        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Photos' recording dates for the given identifiers, keyed by identifier.
    ///
    /// Never prompts: without access already granted this returns nothing, so a list
    /// being drawn can't put up a permission alert.
    static func captureDates(for localIdentifiers: [String]) -> [String: Date] {
        guard !localIdentifiers.isEmpty,
              authorizationStatus == .authorized || authorizationStatus == .limited
        else { return [:] }

        var dates: [String: Date] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
            .enumerateObjects { asset, _, _ in
                dates[asset.localIdentifier] = asset.creationDate
            }
        return dates
    }
}
