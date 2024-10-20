//
//  GameModel.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import Foundation

@Observable
class GameModel {
    let teamOneStats = TeamStatistic.exampleTeamStat1
    let teamTwoStats = TeamStatistic.exampleTeamStat2
    let playerStats = Statistic.exampleStats
}

struct TeamStatistic {
    var teamName: String
    var pointsScored: Int
    var foulsMade: Int
    var rebounds: Int
    var assists: Int
}

extension TeamStatistic {
    static var exampleTeamStat1 = TeamStatistic(teamName: "Team 1", pointsScored: 64, foulsMade: 8, rebounds: 18, assists: 22)
    
    static var exampleTeamStat2 = TeamStatistic(teamName: "Team 2", pointsScored: 59, foulsMade: 11, rebounds: 16, assists: 24)
}
