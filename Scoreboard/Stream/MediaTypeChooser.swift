//
//  AnalyseView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI
import PhotosUI

struct MediaTypeChooser: View {
    // live camera
    @State var showLiveCamera = false
    
    // pre-recorded video
    @State var showLibrary = false
    @State var showVideo = false
    @State var asset: AVURLAsset?
    
    var body: some View {
        HStack {
            Spacer()
            Button("Library") {
                showLibrary.toggle()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            Button {
                showLiveCamera.toggle()
            } label: {
                Text("Live")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .fullScreenCover(isPresented: $showLiveCamera) {
            CameraView(camera: CameraModel(), dismissCam: $showLiveCamera)
        }
        .sheet(isPresented: $showLibrary) {
            VideoPicker(isPresented: $showLibrary, selectedAsset: $asset)
        }
        .onChange(of: asset, { oldValue, newValue in
            if let newValue {
                showVideo.toggle()
            }
        })
        .fullScreenCover(isPresented: $showVideo) {
            VideoView(asset: asset!)
        }
    }
}

#Preview {
    MediaTypeChooser()
}
