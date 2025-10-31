//
//  ScoreboardTabView.swift
//  Scoreboard
//
//  Created by Cam Graham on 13/10/2024.
//

import SwiftUI

struct ScoreboardTabView: View {
    @State var tabSelection: Tabs = .scoreboard
    var body: some View {
        TabView(selection: $tabSelection) {
            Tab(Tabs.scoreboard.name, systemImage: Tabs.scoreboard.symbol, value: Tabs.scoreboard) {
                ScoreboardView()
            }
            
            Tab(Tabs.media.name, systemImage: Tabs.media.symbol, value: Tabs.media) {
                MediaTypeChooser()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

enum Tabs: Identifiable, Hashable {
    case scoreboard
    case media
    
    var id: Int {
        switch self {
        case .scoreboard:
            1
        case .media:
            2
        }
    }
    
    var name: String {
        switch self {
        case .scoreboard:
            "Dashboard"
        case .media:
            "Analyse"
        }
    }
    
    var symbol: String {
        switch self {
        case .scoreboard:
            "basketball.fill"
        case .media:
            "rectangle.dashed.badge.record"
        }
    }
}

#Preview {
    ScoreboardTabView()
}
