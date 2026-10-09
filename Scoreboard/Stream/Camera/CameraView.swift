//
//  CameraView.swift
//  Scoreboard
//
//  Created by Cam Graham on 18/09/2024.
//

import SwiftUI
import Vision
import AVFoundation
import GroupActivities

struct CameraView: View {
    
    @State var camera: CameraModel
    @Binding var dismissCam: Bool
    @State var showActivitySharingSheet = false

    
    var body: some View {
        CameraPreview(source: camera.previewSource)
            .ignoresSafeArea()
        .task {
            await camera.start()
        }
        .overlay {
            PlayerTracksOverlay(tracks: camera.tracker.playerTracks)
        }
        .overlay(alignment: .topLeading) {
            Button("Close") {
                Task {
                    await camera.stop()
                    dismissCam.toggle()
                }
            }
        }
    }
    
    func startActivity() {
        // Does this need to be created outside of view
        
        let stateObserver = GroupStateObserver()
        
        if stateObserver.isEligibleForGroupSession {
            
        } else {
            // GroupActivitySharingController
            showActivitySharingSheet.toggle()
        }
        
    }
    
}

#Preview {
    CameraView(camera: CameraModel(), dismissCam: .constant(false))
}
