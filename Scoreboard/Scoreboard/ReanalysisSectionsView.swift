//
//  ReanalysisSectionsView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI

/// The sections marked for another pass over this video, and the control that runs them.
///
/// Re-analysis replaces whatever the first pass decided about a window, so it is kept
/// behind a deliberate press here rather than offered on the bar itself: it is a rerun of
/// the detector over that footage, not a nudge to an individual shot.
struct ReanalysisSectionsView: View {

    let sections: [ReanalysisSection]
    let reanalyser: SectionReanalyser

    /// Why re-analysis is unavailable, or nil when it can run.
    let blockedReason: String?

    /// Whether to draw the frames while the pass runs.
    @Binding var watches: Bool

    let onReanalyse: () -> Void

    /// Seek the clip behind this sheet to a section.
    let onJump: (ReanalysisSection) -> Void

    let onDelete: (ReanalysisSection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if reanalyser.isRunning {
                    progressSection
                }

                if let summary = reanalyser.summary, !reanalyser.isRunning {
                    resultSection(summary)
                }

                sectionsList

                runSection
            }
            .navigationTitle("Re-analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        // Leaving mid-run would abandon a pass with no way back to it.
                        .disabled(reanalyser.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(reanalyser.isRunning)
    }

    // MARK: Sections

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(activeLabel)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Spacer()
                    Text("\(reanalyser.completedSections + 1) of \(reanalyser.totalSections)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: reanalyser.overallProgress)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Running")
        } footer: {
            Text("Each section is merged as it finishes, so stopping part way still keeps what has been found.")
        }
    }

    private func resultSection(_ summary: SectionReanalyser.Summary) -> some View {
        Section {
            LabeledContent("Sections re-analysed", value: "\(summary.sections)")
            LabeledContent("Shots found", value: "\(summary.found)")
            LabeledContent("Shots replaced", value: "\(summary.removed)")

            if let failure = reanalyser.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Last run")
        } footer: {
            Text(resultFooter(summary))
        }
    }

    private var sectionsList: some View {
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
                .disabled(reanalyser.isRunning)
            }
            .onDelete { offsets in
                for index in offsets { onDelete(sections[index]) }
            }
            .deleteDisabled(reanalyser.isRunning)
        } header: {
            Text("Marked for re-analysis")
        } footer: {
            Text(totalFooter)
        }
    }

    private var runSection: some View {
        Section {
            Toggle(isOn: $watches) {
                Label("Watch it run", systemImage: watches ? "eye" : "eye.slash")
            }
            .disabled(reanalyser.isRunning)

            Button {
                onReanalyse()
            } label: {
                Label(
                    reanalyser.isRunning ? "Re-analysing…" : "Re-analyse marked sections",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(blockedReason != nil || reanalyser.isRunning)
        } footer: {
            Text(blockedReason ?? runFooter)
        }
    }

    private var runFooter: String {
        let base = "Runs the detector over each marked window again and replaces whatever it found there before. Your rulings are keyed to the moment they happened, so they are reapplied to the new shots."

        return watches
            ? base + " The frames will play here as they are analysed."
            : base + " Without watching it finishes sooner, and the progress shows here."
    }

    // MARK: Pieces

    private func row(_ section: ReanalysisSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isActive(section) ? "arrow.clockwise" : "scissors")
                .foregroundStyle(.blue)
                .frame(width: 22)
                .symbolEffect(.pulse, isActive: isActive(section))

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

    private func isActive(_ section: ReanalysisSection) -> Bool {
        reanalyser.activeSection?.id == section.id
    }

    private var activeLabel: String {
        guard let section = reanalyser.activeSection else { return "Starting…" }
        return "\(ShotScrubber.timecode(section.startTime)) – \(ShotScrubber.timecode(section.endTime))"
    }

    private func resultFooter(_ summary: SectionReanalyser.Summary) -> String {
        if summary.found == 0 && summary.removed == 0 {
            return "Nothing changed — the detector saw the same as before, or nothing at all."
        }
        if summary.found == 0 {
            return "The new pass found no shots there, so what was detected before has been removed."
        }
        return "The timeline now shows what the second pass saw in those windows."
    }

    private var totalFooter: String {
        guard !sections.isEmpty else {
            return "Mark a stretch of the video on the scrubber to queue it for another look."
        }

        let total = sections.reduce(0) { $0 + $1.duration }
        return "\(sections.count) section\(sections.count == 1 ? "" : "s"), \(ShotScrubber.length(total)) of footage. Tap one to jump to it, swipe to remove it."
    }
}

#Preview {
    ReanalysisSectionsView(
        sections: [
            ReanalysisSection(startTime: 12, endTime: 20),
            ReanalysisSection(startTime: 95.5, endTime: 101)
        ],
        reanalyser: SectionReanalyser(),
        blockedReason: nil,
        watches: .constant(false),
        onReanalyse: {},
        onJump: { _ in },
        onDelete: { _ in },
        onDismiss: {}
    )
}
