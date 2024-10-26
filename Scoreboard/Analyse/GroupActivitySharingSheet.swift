//
//  GroupActivitySharingSheet.swift
//  Scoreboard
//
//  Created by Cam Graham on 26/10/2024.
//

import SwiftUI
import GroupActivities
import UIKit

struct GroupActivitySharingSheet: UIViewControllerRepresentable {
    typealias UIViewControllerType = GroupActivitySharingController
    
    func makeUIViewController(context: Context) -> GroupActivitySharingController {
//        do {
            let viewController = try! GroupActivitySharingController(ObserveTogether(object: IdentifiedObject(origin: "CamsDevice", name: "Unknown")))
//        } catch {
//            
//        }
        return viewController
        
    }
    
    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
        
    }
}

#Preview {
    GroupActivitySharingSheet()
}
