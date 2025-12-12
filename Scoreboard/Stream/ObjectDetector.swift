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
        guard let customModel = try? best(configuration: .init()).model else {
            throw ObjectError.creation
        }
        let model = try VNCoreMLModel(for: customModel)
        
//        guard let yoloModel = try? YOLOv3Int8LUT(configuration: .init()).model else {
//            throw ObjectError.creation
//        }
//        var model = try VNCoreMLModel(for: yoloModel)
//        model.featureProvider = ThresholdProvider()
        
        return model
    }
}

enum ObjectError: Error {
    case creation
}


class ThresholdProvider: MLFeatureProvider {
    /// The actual values to provide as input
    ///
    /// Create ML Defaults are 0.45 for IOU and 0.25 for confidence.
    /// Here the IOU threshold is relaxed a little bit because there are
    /// sometimes multiple overlapping boxes per die.
    /// Technically, relaxing the IOU threshold means
    /// non-maximum-suppression (NMS) becomes stricter (fewer boxes are shown).
    /// The confidence threshold can also be relaxed slightly because
    /// objects look very consistent and are easily detected on a homogeneous
    /// background.
    open var values = [
        "iouThreshold": MLFeatureValue(double: 0.3),
        "confidenceThreshold": MLFeatureValue(double: 0.15)
    ]


    /// The feature names the provider has, per the MLFeatureProvider protocol
    var featureNames: Set<String> {
        return Set(values.keys)
    }


    /// The actual values for the features the provider can provide
    func featureValue(for featureName: String) -> MLFeatureValue? {
        return values[featureName]
    }
}
