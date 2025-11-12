//
//  VideoView.swift
//  Scoreboard
//
//  Created by Cam Graham on 09/11/2025.
//

import SwiftUI
import AVKit

struct VideoView: View {
    var asset: AVURLAsset
    @State var videoProcessor: VideoProcessor?
    var body: some View {
        VStack {
            if let currentFrame = videoProcessor?.currentFrame {
                currentFrame
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("No Image", systemImage: "plus")
            }
        }
        .background()
        .task {
            do {
                videoProcessor = try await VideoProcessor.create(videoAsset: asset)
            } catch {
                print("error \(error.localizedDescription)")
            }
        }
        .overlay(alignment: .bottom) {
            if videoProcessor == nil {
                Button("Load") {
                    Task {
                        do {
                            videoProcessor = try await VideoProcessor.create(videoAsset: asset)
                        } catch {
                            print("error \(error.localizedDescription)")
                        }
                    }
                }
                .padding(.bottom)
            } else {
                Button("Next") {
                    videoProcessor?.readNextFrame()
                }
                .disabled(videoProcessor == nil)
                .padding(.bottom)
            }
        }
    }
}

//#Preview {
//    VideoView(video: )
//}
