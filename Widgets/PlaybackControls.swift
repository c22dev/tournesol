//
//  PlaybackControls.swift
//  TournesolWidgets
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppIntents
import SwiftUI
import WidgetKit

struct ControlSnapshotProvider: ControlValueProvider {
    var previewValue: ControlSnapshot { .placeholder }

    func currentValue() async throws -> ControlSnapshot {
        .load()
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlSnapshot.kinds[0], provider: ControlSnapshotProvider()) { snapshot in
            ControlWidgetButton(action: RemoteActionIntent(deviceID: ControlSnapshot.currentDevice, action: .togglePlayPause)) {
                Label(snapshot.title ?? snapshot.deviceName, systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Play/Pause")
        .description("Plays or pauses the device selected in Tournesol.")
    }
}

struct NextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlSnapshot.kinds[1], provider: ControlSnapshotProvider()) { snapshot in
            ControlWidgetButton(action: RemoteActionIntent(deviceID: ControlSnapshot.currentDevice, action: .next)) {
                Label("Next on \(snapshot.deviceName)", systemImage: "forward.fill")
            }
        }
        .displayName("Next Track")
        .description("Skips forward on the device selected in Tournesol.")
    }
}

struct PreviousTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlSnapshot.kinds[2], provider: ControlSnapshotProvider()) { snapshot in
            ControlWidgetButton(action: RemoteActionIntent(deviceID: ControlSnapshot.currentDevice, action: .previous)) {
                Label("Previous on \(snapshot.deviceName)", systemImage: "backward.fill")
            }
        }
        .displayName("Previous Track")
        .description("Skips back on the device selected in Tournesol.")
    }
}
