//
//  ScoreboardView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct ScoreboardView: View {
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
                    
                    
                    ForEach(0..<10) { i in
                        RoundedRectangle(cornerRadius: 25)
                            .fill(.regularMaterial)
                            .frame(height: 80)
                        //                                .animated.threshold(.visible(0.9))
                            .scrollTransition { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.75)
                                    .blur(radius: phase.isIdentity ? 0 : 10)
                            }
                            .padding(.horizontal)
                    }
                }
            }
            
            .navigationTitle("Scoreboard")
            .background {
                AnimatedColorsMeshGradientView()
                    .ignoresSafeArea(.all)
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
