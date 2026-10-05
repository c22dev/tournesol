//
//  ControlSnapshot.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import Foundation

nonisolated struct ControlSnapshot: Codable, Hashable, Sendable {
    static let currentDevice = "current"
    static let kinds = [
        "ch.cclerc.Tournesol.control.playpause",
        "ch.cclerc.Tournesol.control.next",
        "ch.cclerc.Tournesol.control.previous",
    ]

    var deviceID: String?
    var deviceName: String
    var deviceSymbol: String
    var title: String?
    var artist: String?
    var isPlaying: Bool

    static let placeholder = ControlSnapshot(deviceID: nil, deviceName: "Tournesol", deviceSymbol: "sun.max.fill", title: nil, artist: nil, isPlaying: false)

    private static let key = "controlSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ArtworkStore.groupID) }

    static func load() -> ControlSnapshot {
        guard let data = defaults?.data(forKey: key), let snapshot = try? JSONDecoder().decode(ControlSnapshot.self, from: data) else { return .placeholder }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }
}
