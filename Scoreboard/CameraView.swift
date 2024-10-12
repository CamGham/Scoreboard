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
        .onReceive(camera.predictionTimer, perform: { _ in
            camera.canPredict = true
        })
        .overlay(alignment: .top) {
            HStack {
                Text(camera.myLabel)
            }
        }
    }
}

#Preview {
    CameraView()
}
