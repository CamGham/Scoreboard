//
//  ReanalysisSectionsView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI

/// The sections marked for another pass over this video.
///
/// Running the pass isn't built yet, so this is a queue rather than a control panel: it
/// exists to show what has been flagged, let a section be revisited or dropped, and keep
/// the marks safe until there is something to hand them to.
struct ReanalysisSectionsView: View {

    let sections: [ReanalysisSection]

    /// Seek the clip behind this sheet to a section.
    let onJump: (ReanalysisSection) -> Void

    let onDelete: (ReanalysisSection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sections.isEmpty {
                        Text("No sections marked")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(sections) { section in
                        Button {
                            onJump(section)
                        } label: {
                            row(section)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { onDelete(sections[index]) }
                    }
                } header: {
                    Text("Marked for re-analysis")
                } footer: {
                    Text(totalFooter)
                }

                Section {
                    Button {
                        // Deliberately inert.
                    } label: {
                        Label("Re-analyse marked sections", systemImage: "arrow.clockwise")
                    }
                    .disabled(true)
                } footer: {
                    Text("Re-running the detector over a section isn't wired up yet. Marks are saved with the video and will be picked up when it is.")
                }
            }
            .navigationTitle("Re-analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private func row(_ section: ReanalysisSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .foregroundStyle(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(ShotScrubber.timecode(section.startTime)) – \(ShotScrubber.timecode(section.endTime))")
                    .font(.body.monospacedDigit())

                Text("\(ShotScrubber.length(section.duration)) · marked \(section.createdAt, format: .dateTime.day().month().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "play.circle")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var totalFooter: String {
        guard !sections.isEmpty else {
            return "Mark a stretch of the video on the scrubber to queue it for another look."
        }

        let total = sections.reduce(0) { $0 + $1.duration }
        return "\(sections.count) section\(sections.count == 1 ? "" : "s"), \(ShotScrubber.length(total)) of footage. Swipe to remove one."
    }
}

#Preview {
    ReanalysisSectionsView(
        sections: [
            ReanalysisSection(startTime: 12, endTime: 20),
            ReanalysisSection(startTime: 95.5, endTime: 101)
        ],
        onJump: { _ in },
        onDelete: { _ in },
        onDismiss: {}
    )
}
