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

    /// The analysis saved to finish later, while asking what to do about it before a new
    /// one starts — see `InProgressSummary`.
    @State var inProgress: InProgressSummary?

    /// The saved pass being carried on from here, while its analysis screen is up.
    @State var continuing: AnalysisSnapshot?

    private let snapshotStore = SnapshotStore()

    var body: some View {
        HStack {
            Spacer()
            Button("Library") {
                // Asked before the picker, not after: a new analysis replaces the saved
                // one, and it's simplest to decide that before choosing anything.
                if let summary = snapshotStore.loadSummary(), summary.canContinue {
                    inProgress = summary
                } else {
                    showVideo.toggle()
                }
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
        .fullScreenCover(isPresented: Binding(get: { continuing != nil }, set: { if !$0 { continuing = nil } })) {
            if let continuing {
                VideoView(continuing: continuing)
            }
        }
        .alert(
            "Analysis in progress",
            isPresented: Binding(get: { inProgress != nil }, set: { if !$0 { inProgress = nil } })
        ) {
            Button("Continue It") {
                if case .ready(let snapshot) = snapshotStore.load() {
                    continuing = snapshot
                }
            }
            Button("Start a New Analysis", role: .destructive) {
                snapshotStore.delete()
                showVideo = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(inProgressMessage)
        }
    }

    /// Which video, and how far it got, in a sentence.
    private var inProgressMessage: String {
        guard let inProgress else { return "" }
        let which = inProgress.capturedAt.map {
            "The video recorded \($0.formatted(.dateTime.day().month())) is"
        } ?? "A video is"
        return "\(which) \(inProgress.percentText ?? inProgress.timeText). Starting a new analysis will lose it."
    }
}

#Preview {
    MediaTypeChooser()
}
