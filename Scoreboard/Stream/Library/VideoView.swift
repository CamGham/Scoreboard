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
        .overlay {
            GeometryReader { geometry in
                ForEach(videoProcessor?.tracker.rects ?? []) { rectData in
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
                ForEach(videoProcessor?.tracker.trackedRects ?? []) { rectData in
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
                HStack(spacing: 20) {
//                    Button("Next") {
//                        let _ = videoProcessor?.readNextFrame()
//                    }
//                    .disabled(videoProcessor == nil)
                    Button("Clear") {
                        videoProcessor?.clear()
                    }
                    
                    
                    Button("Play") {
                        Task {
                            await videoProcessor?.autoReadFrames()
                        }
                    }
                }
                .padding(.bottom)
            }
        }
    }
    
    func adjustRectForView(rect: CGRect, viewSize: CGSize) -> CGRect {
        let scale = CGAffineTransform.identity.scaledBy(x: viewSize.width, y: viewSize.height)
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -viewSize.height)
        return rect.applying(scale).applying(transform)
    }
}

//#Preview {
//    VideoView(video: )
//}
