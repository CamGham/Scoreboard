//
//  AnalyseView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct AnalyseView: View {
    @State var showLiveCamera = false
    var body: some View {
        HStack {
            Button {
                print("Open Recording")
            } label: {
                Text("Library")
            }
            
            Button {
                showLiveCamera.toggle()
            } label: {
                Text("Live")
            }
        }
        .fullScreenCover(isPresented: $showLiveCamera) {
            
            CameraView(dismissCam: $showLiveCamera)
        }
    }
}

#Preview {
    AnalyseView()
}
