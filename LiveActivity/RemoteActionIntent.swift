//
//  RemoteActionIntent.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppIntents

nonisolated enum RemoteAction: String, AppEnum {
    case togglePlayPause, next, previous, volumeUp, volumeDown

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Remote Action"
    static let caseDisplayRepresentations: [RemoteAction: DisplayRepresentation] = [
        .togglePlayPause: "Play/Pause",
        .next: "Next Track",
        .previous: "Previous Track",
        .volumeUp: "Volume Up",
        .volumeDown: "Volume Down",
    ]
}

struct RemoteActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let isDiscoverable = false

    @Parameter(title: "Device")
    var deviceID: String

    @Parameter(title: "Action")
    var action: RemoteAction

    init() {}

    init(deviceID: String, action: RemoteAction) {
        self.deviceID = deviceID
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await RemoteIntentRouter.perform(action, on: deviceID)
        #endif
        return .result()
    }
}
