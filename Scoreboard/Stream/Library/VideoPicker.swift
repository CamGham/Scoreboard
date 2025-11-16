//
//  VideoPicker.swift
//  Scoreboard
//
//  Created by Cam Graham on 11/11/2025.
//

import Foundation
import PhotosUI
import UIKit
import SwiftUI

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedAsset: AVURLAsset?
    @Binding var assetState: AssetState
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.preferredAssetRepresentationMode = .current
        config.selectionLimit = 1
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
   
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }
   
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: PHPickerViewControllerDelegate {
        let parent: VideoPicker
        
        init(parent: VideoPicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard let selectedItem = results.first else {
                parent.assetState = .unSelected
                return
            }
            parent.assetState = .loading
            
            let itemProvider = selectedItem.itemProvider
            guard itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
                parent.assetState = .failed
                return
            }
            
            itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url else {
                    self.parent.assetState = .failed
                    return
                }
                do {
                    let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")

                    if FileManager.default.fileExists(atPath: copy.path()) {
                        try FileManager.default.removeItem(at: copy)
                    }
                
                    try FileManager.default.copyItem(at: url, to: copy)
                    let asset = AVURLAsset(url: copy)
                    self.parent.assetState = .processing
                    self.parent.selectedAsset = asset
                } catch {
                    self.parent.assetState = .failed
                    print("Failed")
                }
            }
        }
    }
}
