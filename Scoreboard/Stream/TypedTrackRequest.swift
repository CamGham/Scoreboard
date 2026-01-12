//
//  TypedTrackRequest.swift
//  Scoreboard
//
//  Created by Cam Graham on 12/12/2025.
//

import Foundation
import Vision

enum ObjectType: String {
    case ball = "Basketball"
    case player = "Player"
}

class TypedTrackRequest: Equatable, Identifiable {
    static func == (lhs: TypedTrackRequest, rhs: TypedTrackRequest) -> Bool {
        lhs.type == rhs.type && rhs.id == lhs.id
    }
    
    let type: ObjectType
    let request: VNTrackObjectRequest
    
    let id = UUID()
    
    var lowConfidenceFrames = 0
    
    init(observation: VNDetectedObjectObservation, type: ObjectType) {
        self.type = type
        self.request = VNTrackObjectRequest(detectedObjectObservation: observation)
    }
}
