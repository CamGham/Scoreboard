//
//  IdentifiedObject.swift
//  Scoreboard
//
//  Created by Cam Graham on 25/10/2024.
//

import Foundation
import GroupActivities
import CoreTransferable

struct IdentifiedObject: Codable, Transferable {
    var origin: String
    var name: String
    
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.origin)
        GroupActivityTransferRepresentation { object in
            ObserveTogether(object: object)
        }
    }
}

struct ObserveTogether: GroupActivity {
    static let activityIdentifier = "com.camgham.maptag"
    
    var object: IdentifiedObject
    
    init(object: IdentifiedObject) {
        self.object = object
    }
}

extension ObserveTogether {
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .watchTogether
        metadata.title = "\(object.origin)"
        
        return metadata
    }
}
