//
//  ScoreboardView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct ScoreboardView: View {
    private let store = ShotStore()

    /// Owns what's pushed, so finishing an analysis can come back to the list. Absent in
    /// previews, which keep their own.
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @State private var previewPath: [SavedGameRoute] = []

    private var path: Binding<[SavedGameRoute]> {
        guard let navigation else { return $previewPath }
        return Binding(get: { navigation.dashboardPath }, set: { navigation.dashboardPath = $0 })
    }

    var body: some View {
        NavigationStack(path: path) {
            
            SavedGamesView(store: store) {
                GroupBox {
                    PreviousGameStats()
                }
                .groupBoxStyle(CustomGroupBox())
                .padding(.vertical)
            }
            .navigationTitle("Scoreboard")
            .background {
                if #available(iOS 18.0, *) {
                    AnimatedColorsMeshGradientView()
                        .ignoresSafeArea(.all)
                } else {
                    // Fallback on earlier versions
                    Color(.systemBackground)
                        .ignoresSafeArea(.all)
                }
            }
        }
    }
}

#Preview {
    ScoreboardView()
}


struct CustomGroupBox: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            configuration.label
            configuration.content
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
