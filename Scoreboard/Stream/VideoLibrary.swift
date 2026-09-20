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
}
