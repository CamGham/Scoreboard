//
//  GameView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct GameView: View {
    var teamOne: TeamStatistic
    var teamTwo: TeamStatistic
    var body: some View {
        HStack {
            Spacer()
            
            VStack {
                Text("\(teamOne.pointsScored)")
                    .font(.largeTitle)
                Text("\(teamOne.teamName)")
            }
            
            
            Spacer()
            
            VStack {
                Text("\(teamTwo.pointsScored)")
                    .font(.largeTitle)
                Text("\(teamTwo.teamName)")
            }
            
            Spacer()
        }
        
    }
}

#Preview {
    GameView(teamOne: TeamStatistic.exampleTeamStat1, teamTwo: TeamStatistic.exampleTeamStat2)
}
