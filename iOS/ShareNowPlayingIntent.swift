//
//  ShareNowPlayingIntent.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppIntents

struct ShareNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Share Now Playing"
    static let description = IntentDescription("Wakes Tournesol for a few seconds so your paired devices see what's playing. Run it from a “When Music is opened” automation.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await AppModel.shared.shareNowPlaying()
        return .result()
    }
}

struct TournesolShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShareNowPlayingIntent(),
            phrases: ["Share now playing with \(.applicationName)"],
            shortTitle: "Share Now Playing",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
