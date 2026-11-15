//
//  AppNavigation.swift
//  Scoreboard
//
//  Created by Cam Graham on 23/10/2026.
//

import SwiftUI

/// Where the app is, for screens that need to send the user somewhere else — the
/// analysis screen, once a run is saved, hands over to the dashboard's row for it.
@Observable
final class AppNavigation {
    var tab: Tabs = .scoreboard

    /// A saved game the dashboard should bring into view, by Photos identifier. Cleared
    /// once it has been shown.
    var gameToShow: String?

    /// What the dashboard has pushed: the saved games opened from its list.
    var dashboardPath: [SavedGameRoute] = []

    /// Switch to the dashboard, back to its list, and bring a saved game's row into view.
    func showSavedGame(_ assetIdentifier: String) {
        dashboardPath = []
        gameToShow = assetIdentifier
        tab = .scoreboard
    }
}

/// A saved game opened from the dashboard's list.
struct SavedGameRoute: Hashable {
    let assetIdentifier: String
}
