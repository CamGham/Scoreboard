//
//  CameraView.swift
//  Scoreboard
//
//  Created by Cam Graham on 18/09/2024.
//

import SwiftUI
import Vision
import AVFoundation

struct CameraView: View {
    @State var camera = CameraModel()
    
    var body: some View {
        CameraPreview(source: camera.previewSource)
        .task {
            await camera.start()
        }
    }
}

#Preview {
    CameraView()
}
