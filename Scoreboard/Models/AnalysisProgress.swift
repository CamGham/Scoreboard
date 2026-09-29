//
//  AnalysisProgress.swift
//  Scoreboard
//
//  Created by Cam Graham on 24/09/2026.
//

import Foundation

/// How far an analysis pass has got, and how fast.
///
/// Measured in *media* seconds against wall-clock seconds, which is the only honest way
/// to do it: frames are not uniform on variable-frame-rate footage, and the detector's
/// cost per frame swings with how much is happening in shot. A rate derived from the two
/// clocks describes what the user is actually waiting for.
///
/// Pure, so the estimate can be tested without running an analysis.
struct AnalysisProgress: Equatable {

    /// Media time analysed so far.
    let analysedSeconds: Double

    /// Length of the clip.
    let clipSeconds: Double

    /// Wall-clock time since the pass started.
    let elapsedSeconds: Double

    init(analysedSeconds: Double, clipSeconds: Double, elapsedSeconds: Double) {
        self.analysedSeconds = max(0, analysedSeconds)
        self.clipSeconds = max(0, clipSeconds)
        self.elapsedSeconds = max(0, elapsedSeconds)
    }

    /// 0–1 through the clip. A clip of unknown length reads as zero rather than guessing.
    var fraction: Double {
        guard clipSeconds > 0 else { return 0 }
        return min(max(analysedSeconds / clipSeconds, 0), 1)
    }

    var isFinished: Bool {
        clipSeconds > 0 && analysedSeconds >= clipSeconds - 0.05
    }

    /// Media seconds analysed per wall-clock second — "3.4× real time".
    ///
    /// Nil for the first moment of a run: the model loads on the first frames, so an
    /// early rate would read far slower than the pass actually settles at, and a number
    /// that halves as you watch it is worse than no number.
    var speed: Double? {
        guard elapsedSeconds >= 1.0, analysedSeconds > 0 else { return nil }
        return analysedSeconds / elapsedSeconds
    }

    /// Wall-clock seconds left, from the rate so far.
    var remainingSeconds: Double? {
        guard !isFinished, clipSeconds > 0, let speed, speed > 0 else { return nil }
        return max(0, (clipSeconds - analysedSeconds) / speed)
    }

    /// Rounded to something worth saying out loud — a countdown to the second would be
    /// both jittery and more precise than the estimate deserves.
    var remainingDescription: String? {
        guard let remaining = remainingSeconds else { return nil }

        if remaining < 10 { return "a few seconds left" }
        if remaining < 60 { return "about \(Int((remaining / 5).rounded()) * 5)s left" }

        let minutes = Int((remaining / 60).rounded())
        return "about \(minutes) min left"
    }
}
