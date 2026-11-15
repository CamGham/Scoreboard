//
//  BackgroundTaskWindow.swift
//  Scoreboard
//
//  Created by Cam Graham on 10/11/2026.
//

import UIKit

/// Extra time to finish something as the app goes to the background — about thirty
/// seconds at most, and not promised.
///
/// Every start has to be ended exactly once: when the work is done, or when iOS says time
/// is up, whichever comes first. Ending on both would end someone else's task, and never
/// ending gets the app killed. This makes `end()` safe to call from either.
@MainActor
final class BackgroundTaskWindow {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Called on the main thread when time runs out.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
