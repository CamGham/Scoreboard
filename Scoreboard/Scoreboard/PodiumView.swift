//
//  PodiumView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct PodiumView: View {
    var statistics: [Statistic]
    let rotationTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    
    @State var chosenStat: Statistic?
    
    var remainingStats: [Statistic] {
        guard let chosenStat else {
            return statistics
        }
        
        return statistics.filter { stat in
            stat != chosenStat
        }
    }
    
    @Namespace var podium
    
    var body: some View {
        VStack {
            if let chosenStat {
                HStack {
                    Spacer()
                    Text("\(chosenStat.value.formatted())")
                        .font(.largeTitle)
                    + Text(" \(chosenStat.name)")
                }
                .matchedGeometryEffect(id: chosenStat.id, in: podium)
            }
            HStack {
                Spacer()
                ForEach(remainingStats, id: \.self) { stat in
                    HStack {
                        Text("\(stat.value.formatted())")
                        + Text(" \(stat.name)")
                    }
                    .matchedGeometryEffect(id: stat.id, in: podium)
                }
            }
        }
        .padding()
        .onAppear {
            if chosenStat == nil {
                rotateStats()
            }
        }
        .onReceive(rotationTimer, perform: { _ in
            rotateStats()
        })
        
    }
    
    func rotateStats() {
        if let chosenStat,
           let currentIndex = statistics.firstIndex(of: chosenStat) {
            let nextIndex = (currentIndex + 1) % statistics.count
            
            withAnimation {
                self.chosenStat = statistics[nextIndex]
            }
        } else {
            chosenStat = statistics.first
        }
    }
}

#Preview {
    PodiumView(statistics: [Statistic(name: "points", value: 12), Statistic(name: "assists", value: 4), Statistic(name: "blocks", value: 3), Statistic(name: "rebounds", value: 8)])
}
