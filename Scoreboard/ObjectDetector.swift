//
//  ObjectDetector.swift
//  Scoreboard
//
//  Created by Cam Graham on 19/10/2024.
//

import Foundation
import Vision

class ObjectDetector {
    static func createDetector() async throws -> VNCoreMLModel {
        guard let yoloModel = try? YOLOv3Int8LUT(configuration: .init()).model else {
            throw ObjectError.creation
        }

        return try VNCoreMLModel(for: yoloModel)
    }
}

enum ObjectError: Error {
    case creation
}
