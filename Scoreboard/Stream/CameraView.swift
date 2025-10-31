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
        .onReceive(camera.predictionTimer, perform: { _ in
            camera.canPredict = true
        })
        .overlay {
            GeometryReader { geometry in
                ForEach(camera.rects) { rectData in
                    let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                    Rectangle()
                        .stroke(rectData.colour, lineWidth: 2)
                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                        .position(x: adjustedRect.midX, y: adjustedRect.midY)
                    Text("\(rectData.label) \(rectData.id)")
                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                        .foregroundColor(.red)
                    Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                        .foregroundColor(.red)
                }
            }
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
    
    func adjustRectForView(rect: CGRect, viewSize: CGSize) -> CGRect {
        let scale = CGAffineTransform.identity.scaledBy(x: viewSize.width, y: viewSize.height)
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -viewSize.height)
        return rect.applying(scale).applying(transform)
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
