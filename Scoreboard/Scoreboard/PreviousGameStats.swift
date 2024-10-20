//
//  PreviousGameStats.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct PreviousGameStats: View {
    @State var gameModel = GameModel()
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Sundays' game")
                .font(.headline)
            Text(Date.now.formatted(date: .long, time: .shortened))
                .font(.footnote)
            
            // Game
            GameView(
                teamOne: gameModel.teamOneStats,
                teamTwo: gameModel.teamTwoStats
            )
            .padding(.vertical)
            
            
            
            // Player
            VStack(alignment: .leading) {
                Text("Your stats")
                
                HStack {
                    Image(systemName: "tshirt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80)
                        .overlay {
                            Text("1")
                                .font(.title3.bold())
                        }
                    
                    Spacer()
                    
                    PodiumView(statistics: gameModel.playerStats)
                }
            }
            .padding(.top)

        }
        .padding()
    }
}



struct Statistic: Identifiable, Hashable, Equatable {
    var name: String
    var id: String {
        name
    }
    // double for averages
    var value: Double
}

extension Statistic {
    static let exampleStats = [Statistic(name: "points", value: 12), Statistic(name: "assists", value: 4), Statistic(name: "blocks", value: 3), Statistic(name: "rebounds", value: 8)]
}

#Preview {
    PreviousGameStats()
}
