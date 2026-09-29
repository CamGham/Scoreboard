//
//  ReanalysisSection.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/09/2026.
//

import Foundation

/// A stretch of a clip the user has flagged to be analysed again.
///
/// Marks are user input, not detector output, so they live with the corrections rather
/// than inside a run: re-analysing a video must not throw away the note that a section
/// still needs looking at. Nothing here records *why* — a range is the whole instruction,
/// and a reason the pass can't act on would only be a field to keep in step.
struct ReanalysisSection: Codable, Identifiable, Equatable {

    let id: UUID

    var startTime: Double
    var endTime: Double

    var createdAt: Date

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
    }

    var range: ClosedRange<Double> { startTime...max(startTime, endTime) }

    var duration: Double { max(0, endTime - startTime) }

    /// Shortest section worth marking. Below about half a second there is nothing for a
    /// detector to work with — a shot needs several frames of flight to fit an arc to.
    static let minimumDuration: Double = 0.5

    /// Fit a range to the clip: inside the media, and long enough to analyse.
    ///
    /// Clamping happens here rather than in the gesture so a mark made by dragging and a
    /// mark made any other way can't disagree about what is valid.
    static func normalised(
        _ range: ClosedRange<Double>,
        clipDuration: Double
    ) -> ClosedRange<Double> {

        let limit = clipDuration > 0 ? clipDuration : range.upperBound
        let minimum = min(minimumDuration, limit)

        // A `ClosedRange` is ordered by construction, so only the clip's bounds and the
        // minimum length are in question here.
        var start = min(max(range.lowerBound, 0), limit)
        var end = min(max(range.upperBound, 0), limit)

        // Grow a too-short range rather than rejecting it — the user pointed at a moment,
        // and pushing back on the exact length would be pedantic. Prefer to extend
        // forwards, falling back to extending backwards at the end of the clip.
        if end - start < minimum {
            end = min(start + minimum, limit)
            start = max(0, min(start, end - minimum))
        }

        return start...max(start, end)
    }
}

/// Every section marked on one video.
///
/// Its own file in the video's directory, for the same reason corrections have theirs:
/// a different lifetime from the runs. Kept separate from `GroundTruthDocument` because
/// this is a request about work still to do, not a statement about what happened.
struct ReanalysisPlan: Codable, Equatable {

    static let currentVersion = 1

    var version = ReanalysisPlan.currentVersion
    var assetIdentifier: String

    /// In playing order.
    var sections: [ReanalysisSection] = []

    init(assetIdentifier: String, sections: [ReanalysisSection] = []) {
        self.assetIdentifier = assetIdentifier
        self.sections = sections.sorted { $0.startTime < $1.startTime }
    }

    /// Mark a range, absorbing anything it already touches.
    mutating func mark(
        _ range: ClosedRange<Double>,
        clipDuration: Double,
        at date: Date = Date()
    ) {
        sections = sections.marking(range, clipDuration: clipDuration, at: date)
    }

    mutating func remove(_ id: UUID) {
        sections.removeAll { $0.id == id }
    }

    /// How much footage is waiting to be looked at again.
    var totalDuration: Double {
        sections.reduce(0) { $0 + $1.duration }
    }

    /// The section containing a moment, for telling the user they are inside a mark.
    func section(at time: Double) -> ReanalysisSection? {
        sections.first { $0.range.contains(time) }
    }
}

extension Array where Element == ReanalysisSection {

    /// Add a marked range, merging anything it overlaps or touches.
    ///
    /// Two marks over the same footage are one stretch to re-analyse, so they are merged
    /// rather than stacked — otherwise re-marking a section you had already flagged would
    /// quietly queue the same frames twice. The survivor keeps the oldest identity, so
    /// the list doesn't reshuffle under the user when they extend a mark.
    ///
    /// Kept on the array rather than on `ReanalysisPlan` so a view holding just the
    /// sections can use it without inventing a document to put them in.
    func marking(
        _ range: ClosedRange<Double>,
        clipDuration: Double,
        at date: Date = Date()
    ) -> [ReanalysisSection] {

        let fitted = ReanalysisSection.normalised(range, clipDuration: clipDuration)

        let touching = filter { $0.startTime <= fitted.upperBound && fitted.lowerBound <= $0.endTime }

        let merged = ReanalysisSection(
            id: touching.min(by: { $0.createdAt < $1.createdAt })?.id ?? UUID(),
            startTime: Swift.min(fitted.lowerBound, touching.map(\.startTime).min() ?? fitted.lowerBound),
            endTime: Swift.max(fitted.upperBound, touching.map(\.endTime).max() ?? fitted.upperBound),
            createdAt: touching.map(\.createdAt).min() ?? date
        )

        var result = filter { section in !touching.contains { $0.id == section.id } }
        result.append(merged)

        return result.sorted { $0.startTime < $1.startTime }
    }
}
