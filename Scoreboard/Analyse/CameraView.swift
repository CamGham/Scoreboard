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
    @State var camera = CameraModel()
//    @State var showHumanSegmentation = false
    
    @Binding var dismissCam: Bool
    @State var showActivitySharingSheet = false
    
    var identifiedObject: IdentifiedObject = IdentifiedObject(origin: "Cam", name: "Nothing")
    
    var body: some View {
        CameraPreview(source: camera.previewSource)
            .ignoresSafeArea()
        .task {
            await camera.start()
        }
        .onReceive(camera.predictionTimer, perform: { _ in
            camera.canPredict = true
        })
//        .overlay(alignment: .center) {
//            if showHumanSegmentation,
//               let img = camera.myImage {
//                
//       
//                Image(img, scale: 1.0, label: Text(""))
//            }
//        }
//        .overlay(alignment: .topTrailing, content: {
//            Button {
//                showHumanSegmentation.toggle()
//            } label: {
//                Text("Segmentation")
//            }
//
//        })
        .overlay {
            GeometryReader { geometry in
                ForEach(camera.rects) { rectData in
                    let adjustedRect = adjustRectForView(rect: rectData.rect, viewSize: geometry.size)
                    Rectangle()
                        .stroke(Color.red, lineWidth: 2)
                        .frame(width: adjustedRect.width, height: adjustedRect.height)
                        .position(x: adjustedRect.midX, y: adjustedRect.midY)
                    Text("\(rectData.label) (\(Int(rectData.confidence * 100))%)")
                        .position(x: adjustedRect.midX, y: adjustedRect.minY - 10)
                        .foregroundColor(.red)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Close") {
                dismissCam.toggle()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                startActivity()
            } label: {
                Label("Start Activity", systemImage: "shareplay")
            }
//            ShareLink(item: identifiedObject, preview: SharePreview(identifiedObject.origin))
        }
        .task {
            for await session in ObserveTogether.sessions() {
                
                session.join()
            }
        }
        .sheet(isPresented: $showActivitySharingSheet) {
            GroupActivitySharingSheet()
        }
    }
    
    func adjustRectForView(rect: CGRect, viewSize: CGSize) -> CGRect {
        let scaleX = viewSize.width / camera.bufferSize.width
            let scaleY = viewSize.height / camera.bufferSize.height
            let scaledWidth = rect.width * scaleX
            let scaledHeight = rect.height * scaleY
            let scaledX = rect.origin.x * scaleX
            let scaledY = viewSize.height - (rect.origin.y * scaleY) - scaledHeight
            
            return CGRect(x: scaledX, y: scaledY, width: scaledWidth, height: scaledHeight)
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
    CameraView(dismissCam: .constant(false))
}
