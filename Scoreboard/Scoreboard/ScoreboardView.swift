//
//  ScoreboardView.swift
//  Scoreboard
//
//  Created by Cam Graham on 20/10/2024.
//

import SwiftUI

struct ScoreboardView: View {
    var body: some View {
        ScrollView {
            PreviousGameStats()
        }
    }
}

#Preview {
    ScoreboardView()
}
