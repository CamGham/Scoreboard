//
//  ScoreboardView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct ScoreboardView: View {
    private let store = ShotStore()

    var body: some View {
        NavigationStack {
            
            ScrollView {
                LazyVStack {
                    GroupBox {
                        PreviousGameStats()
                    }
                    .groupBoxStyle(CustomGroupBox())
                    .padding()
                    .scrollTransition { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1 : 0)
                        //                        .scaleEffect(phase.isIdentity ? 1 : 0.75)
                            .blur(radius: phase.isIdentity ? 0 : 2)
                    }
                    
                    
                    SavedGamesView(store: store)
                        .padding(.horizontal)
                }
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
