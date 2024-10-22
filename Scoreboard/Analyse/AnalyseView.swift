//
//  AnalyseView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI
import PhotosUI

struct AnalyseView: View {
    @State var showLiveCamera = false
    @State var selectedImages: [PhotosPickerItem] = [] {
        didSet {
            
        }
    }
    var body: some View {
        HStack {
            Spacer()
            PhotosPicker(selection: $selectedImages, photoLibrary: .shared()) {
                Text("Library")
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
            CameraView(dismissCam: $showLiveCamera)
        }
    }
}

#Preview {
    AnalyseView()
}
