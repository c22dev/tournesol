//
//  MacSettingsView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import ApplicationServices
import SwiftUI

struct MacSettingsView: View {
    let model: AppModel
    @AppStorage(MediaKeyController.enabledKey) private var mediaKeysEnabled = true
    @AppStorage(MediaKeyController.volumeKey) private var volumeKeysEnabled = true
    @State private var isTrusted = AXIsProcessTrusted()
    @AppStorage(NowPlayingBridge.enabledKey) private var nowPlayingEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Control the selected device with media keys", isOn: $mediaKeysEnabled)
                Toggle("Include volume and mute keys", isOn: $volumeKeysEnabled)
                    .disabled(!mediaKeysEnabled)
                LabeledContent("Accessibility access") {
                    if isTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") { model.mediaKeys.requestAccess() }
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("When This Mac is selected, media keys keep controlling Music as usual.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show remote devices in Now Playing", isOn: $nowPlayingEnabled)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("When another device is selected, it appears in Control Center, the menu bar and on your AirPods controls like a local player. No audio is played on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section("Paired Devices") {
                let peers = model.hub.security.trusted.sorted { $0.value.name < $1.value.name }
                if peers.isEmpty {
                    Text("No paired devices yet. Open Tournesol on your iPhone or iPad and choose Pair.")
                        .foregroundStyle(.secondary)
                }
                ForEach(peers, id: \.key) { id, peer in
                    LabeledContent {
                        Button("Forget", role: .destructive) { model.hub.store.onForget(id) }
                    } label: {
                        Label(peer.name, systemImage: peer.kind.symbol)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                isTrusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
