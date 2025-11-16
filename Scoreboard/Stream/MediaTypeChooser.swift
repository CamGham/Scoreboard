//
//  AnalyseView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI
import PhotosUI

struct MediaTypeChooser: View {
    @State var showLiveCamera = false
    @State var showVideo = false
    
    var body: some View {
        HStack {
            Spacer()
            Button("Library") {
                showVideo.toggle()
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
        .fullScreenCover(isPresented: $showVideo) {
            VideoView()
        }
    }
}

#Preview {
    MediaTypeChooser()
}
