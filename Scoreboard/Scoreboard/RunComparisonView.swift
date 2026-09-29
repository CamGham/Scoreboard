//
//  RunComparisonView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import SwiftUI

/// Compares two analysis runs of the same video against the user's rulings.
struct RunComparisonView: View {

    let assetIdentifier: String
    let store: ShotStore
    let onDismiss: () -> Void

    @State private var runs: [RunMetadata] = []
    @State private var baselineID: UUID?
    @State private var candidateID: UUID?
    @State private var comparison: RunComparison?
    @State private var isLoading = true

    /// Hide the shots where both runs agreed, which is usually most of them.
    @State private var showOnlyChanges = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if runs.count < 2 {
                    ContentUnavailableView {
                        Label("Only one analysis", systemImage: "square.on.square.dashed")
                    } description: {
                        Text("Analyse this video again to compare the results.")
                    }
                } else if let comparison {
                    content(comparison)
                }
            }
            .navigationTitle("Compare runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .task { load() }
    }

    // MARK: Content

    private func content(_ comparison: RunComparison) -> some View {
        List {
            Section("Runs") {
                runPicker("Baseline", selection: $baselineID)
                runPicker("Candidate", selection: $candidateID)
            }

            if comparison.rows.isEmpty {
                Section {
                    Text("No shots have been ruled on yet, so there is nothing to compare against. Review some shots first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                verdictSection(comparison)
                changesSection(comparison)
                shotsSection(comparison)
            }
        }
        .onChange(of: baselineID) { _, _ in rebuild() }
        .onChange(of: candidateID) { _, _ in rebuild() }
    }

    private func runPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            ForEach(runs) { run in
                Text(runLabel(run)).tag(Optional(run.id))
            }
        }
    }

    private func runLabel(_ run: RunMetadata) -> String {
        let when = run.analysedAt.formatted(.dateTime.day().month().hour().minute())
        return "\(when) · \(run.makes)/\(run.attempts)"
    }

    // MARK: Verdict

    private func verdictSection(_ comparison: RunComparison) -> some View {
        Section {
            HStack(spacing: 0) {
                accuracyColumn(
                    "Baseline",
                    correct: comparison.baselineCorrect,
                    total: comparison.rows.count,
                    percentage: comparison.baselineAccuracy
                )

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 32)

                accuracyColumn(
                    "Candidate",
                    correct: comparison.candidateCorrect,
                    total: comparison.rows.count,
                    percentage: comparison.candidateAccuracy
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            LabeledContent("Fixed") {
                Text("\(comparison.improved.count)")
                    .foregroundStyle(comparison.improved.isEmpty ? Color.secondary : Color.green)
            }
            LabeledContent("Broken") {
                Text("\(comparison.regressed.count)")
                    .foregroundStyle(comparison.regressed.isEmpty ? Color.secondary : Color.red)
            }
            LabeledContent("Net") {
                Text(comparison.netChange > 0 ? "+\(comparison.netChange)" : "\(comparison.netChange)")
                    .fontWeight(.semibold)
                    .foregroundStyle(netColour(comparison.netChange))
            }
        } header: {
            Text("Result")
        } footer: {
            Text(confidenceNote(comparison))
        }
    }

    private func accuracyColumn(
        _ title: String,
        correct: Int,
        total: Int,
        percentage: Double
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", percentage))
                .font(.title2.bold().monospacedDigit())
            Text("\(correct) of \(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func netColour(_ net: Int) -> Color {
        if net > 0 { return .green }
        if net < 0 { return .red }
        return .secondary
    }

    /// Says plainly how much weight the numbers can carry.
    private func confidenceNote(_ comparison: RunComparison) -> String {
        var parts: [String] = []

        parts.append("Judged on \(comparison.rows.count) reviewed "
                     + (comparison.rows.count == 1 ? "shot" : "shots") + ".")

        if comparison.unreviewedAttempts > 0 {
            parts.append("\(comparison.unreviewedAttempts) more "
                         + (comparison.unreviewedAttempts == 1 ? "attempt has" : "attempts have")
                         + " no ruling and can't be judged.")
        }

        if comparison.isSameConfiguration {
            parts.append("Both runs used identical settings, so any difference here is "
                         + "noise rather than the effect of a change.")
        }

        return parts.joined(separator: " ")
    }

    // MARK: Configuration

    @ViewBuilder
    private func changesSection(_ comparison: RunComparison) -> some View {
        Section("What changed") {
            if comparison.configurationChanges.isEmpty {
                Text("No settings differ between these runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comparison.configurationChanges, id: \.self) { change in
                    Label(change, systemImage: "slider.horizontal.3")
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Per-shot

    @ViewBuilder
    private func shotsSection(_ comparison: RunComparison) -> some View {
        let visible = showOnlyChanges
            ? comparison.rows.filter { $0.change.isInteresting }
            : comparison.rows

        Section {
            Toggle("Only show shots that changed", isOn: $showOnlyChanges)
                .font(.callout)

            if visible.isEmpty {
                Text(showOnlyChanges
                     ? "No shot changed verdict between these runs."
                     : "No reviewed shots.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(visible) { row in
                ComparisonRowView(row: row)
            }
        } header: {
            Text("Shots")
        } footer: {
            Text("Each row is a moment you ruled on, and what each run said about it.")
        }
    }

    // MARK: Loading

    private func load() {
        runs = store.runs(for: assetIdentifier)

        // Default to the two most recent: newest as candidate, the one before as
        // baseline, which is the comparison you almost always want.
        candidateID = runs.first?.id
        baselineID = runs.dropFirst().first?.id

        rebuild()
        isLoading = false
    }

    private func rebuild() {
        guard let baselineID, let candidateID,
              let baseline = store.loadRun(baselineID, for: assetIdentifier),
              let candidate = store.loadRun(candidateID, for: assetIdentifier) else {
            comparison = nil
            return
        }

        let truth = store.loadTruth(for: assetIdentifier)

        comparison = RunComparator.compare(
            baseline: baseline,
            candidate: candidate,
            truth: truth.shots
        )
    }
}

private struct ComparisonRowView: View {
    let row: RunComparison.Row

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timecode(row.truth.timeSeconds))
                        .font(.caption.monospacedDigit())
                    Text("you said \(row.truth.verdict.label.lowercased())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    callChip(row.baseline)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    callChip(row.candidate)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func callChip(_ call: RunComparison.Call) -> some View {
        Text(call.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((call.isCorrect ? Color.green : Color.red).opacity(0.15), in: Capsule())
            .foregroundStyle(call.isCorrect ? Color.green : Color.red)
    }

    private var symbol: String {
        switch row.change {
        case .improved: return "arrow.up.circle.fill"
        case .regressed: return "arrow.down.circle.fill"
        case .bothRight: return "equal.circle"
        case .bothWrong: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch row.change {
        case .improved: return .green
        case .regressed: return .red
        case .bothRight: return .secondary
        case .bothWrong: return .orange
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
