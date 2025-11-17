//
//  VideoView.swift
//  Scoreboard
//
//  Created by Cam Graham on 09/11/2025.
//

import SwiftUI
import AVKit

enum AssetState {
    case unSelected
    case loading
    case processing
    case failed
    case ready
}
struct VideoView: View {
    @Environment(\.dismiss) var dismiss
    
    @State var asset: AVURLAsset?
    @State var videoProcessor: VideoProcessor?
    
    @State var showLibrary = false
    @State var assetState = AssetState.unSelected
    var body: some View {
        VStack {
            switch assetState {
            case .unSelected:
                ContentUnavailableView {
                    Label("No video selected", systemImage: "video.fill")
                } description: {
                    Text("Tap the button below to get started")
                } actions: {
                    Button("Open Library", systemImage: "photo.badge.plus.fill") {
                        showLibrary.toggle()
                    }
                }
            case .failed:
                ContentUnavailableView {
                    Label("Could not load video", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text("Something went wrong when loading the video. Please try again.")
                } actions: {
                    Button("Open Library", systemImage: "photo.badge.plus.fill") {
                        showLibrary.toggle()
                    }
                }
            case .loading, .processing:
                ProgressView("Loading...")
            case .ready:
                if let videoProcessor, let currentFrame = videoProcessor.currentFrame {
                    currentFrame
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            GeometryReader { geometry in
                                ForEach(videoProcessor.tracker.rects) { rectData in
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
                                ForEach(videoProcessor.tracker.trackedRects) { rectData in
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
                            if #available(iOS 26.0, *) {
                                Button {
                                    if videoProcessor.playback == .pause {
                                        withAnimation {
                                            videoProcessor.playback = .resume
                                        }
                                        Task {
                                            await videoProcessor.play()
                                        }
                                    } else {
                                        withAnimation {
                                            videoProcessor.playback = .pause
                                        }
                                    }
                                } label: {
                                    Image(systemName: videoProcessor.playback == PlaybackState.pause ? "play.fill" : "pause.fill")
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .contentTransition(.symbolEffect(.replace))
                                .padding(.bottom)
                            } else {
                                Button {
                                    if videoProcessor.playback == .pause {
                                        withAnimation {
                                            videoProcessor.playback = .resume
                                        }
                                        Task {
                                            await videoProcessor.play()
                                        }
                                    } else {
                                        withAnimation {
                                            videoProcessor.playback = .pause
                                        }
                                    }
                                } label: {
                                    Image(systemName: videoProcessor.playback == PlaybackState.pause ? "play.fill" : "pause.fill")
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)
                                .contentTransition(.symbolEffect(.replace))
                                .padding(.bottom)
                            }
                        }
                }
            }
            
        }
        .overlay(alignment: .topLeading, content: {
            Group {
                if #available(iOS 26.0, *) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .padding(4)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                }
            }
            .padding(.leading, 4)
        })
        .sheet(isPresented: $showLibrary) {
            VideoPicker(isPresented: $showLibrary, selectedAsset: $asset, assetState: $assetState)
        }
        .onAppear(perform: {
            showLibrary = true
        })
        .task(id: asset) {
            guard let asset else { return }
            assetState = .processing
            do {
                videoProcessor = try await VideoProcessor.create(videoAsset: asset)
                assetState = .ready
            } catch {
                assetState = .failed
                print("error \(error.localizedDescription)")
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
