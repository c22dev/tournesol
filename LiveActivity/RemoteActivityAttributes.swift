//
//  RemoteActivityAttributes.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import ActivityKit
import Foundation

nonisolated struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var timestamp: Date
        var artworkID: String?
        var outputName: String?
        var outputSymbol: String?
        var tint: RGB?
        var isConnected: Bool
    }

    var deviceID: String
    var deviceName: String
    var deviceSymbol: String
}
