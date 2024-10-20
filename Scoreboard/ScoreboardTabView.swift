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
            
            Tab(Tabs.analyse.name, systemImage: Tabs.analyse.symbol, value: Tabs.analyse) {
                AnalyseView()
            }
            
           
            
            Tab(Tabs.profile.name,
                systemImage: Tabs.profile.symbol, value: Tabs.profile) {
               
                
                List {
                    Text("Profile")
//                    Tab(Tabs.history.name, systemImage: Tabs.history.symbol, value: Tabs.history) {
//                        Text("world")
//                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

enum Tabs: Identifiable, Hashable {
    case scoreboard
    case analyse
    case history
    case profile
    
    var id: Int {
        switch self {
        case .scoreboard:
            1
        case .analyse:
            2
        case .history:
            3
        case .profile:
            4
        }
    }
    
    var name: String {
        switch self {
        case .scoreboard:
            "Dashboard"
        case .analyse:
            "Analyse"
        case .history:
            "History"
        case .profile:
            "Profile"
        }
    }
    
    var symbol: String {
        switch self {
        case .scoreboard:
            "basketball.fill"
        case .analyse:
            "rectangle.dashed.badge.record"
        case .history:
            "list.and.film"
        case .profile:
            "person.text.rectangle.fill"
        }
    }
}

#Preview {
    ScoreboardTabView()
}
