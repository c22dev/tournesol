//
//  RootView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

struct RootView: View {
    let model: AppModel
    @Bindable private var store: DeviceStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsDevices = false

    init(model: AppModel) {
        self.model = model
        store = model.hub.store
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    DeviceSidebar(store: store)
                        .toolbar {
                            RenameButton(model: model)
                            SettingsButton()
                        }
                } detail: {
                    if let device = store.selected {
                        RemoteView(device: device)
                    }
                }
            } else if let device = store.selected {
                RemoteView(device: device) { showsDevices = true }
                    .sheet(isPresented: $showsDevices) {
                        DevicePickerSheet(model: model)
                    }
            }
        }
        .tint(RGB.sunflower.color)
        .environment(store)
        .sheet(item: $store.pairingPrompt) { prompt in
            PairingView(prompt: prompt)
                .presentationDetents([.height(460)])
                .presentationBackground(.thinMaterial)
                .interactiveDismissDisabled()
        }
        .onChange(of: store.pairingPrompt == nil) { _, isIdle in
            if !isIdle { showsDevices = false }
        }
    }
}

private struct DevicePickerSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var store: DeviceStore { model.hub.store }

    var body: some View {
        NavigationStack {
            DeviceGallery(store: store) { device in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    store.selectedID = device.id
                }
                dismiss()
            } onPair: { device in
                dismiss()
                store.onPair(device)
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { RenameButton(model: model) }
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
    }
}

private struct RenameButton: View {
    let model: AppModel
    @State private var isRenaming = false
    @State private var name = ""

    var body: some View {
        Button("Rename", systemImage: "pencil") {
            name = model.hub.local.info.name
            isRenaming = true
        }
        .alert("Device Name", isPresented: $isRenaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(to: name) }
        } message: {
            Text("This is how your \(model.hub.local.info.kind.displayName) appears on your other devices.")
        }
    }
}

private struct SettingsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button("Settings", systemImage: "gearshape") { isPresented = true }
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    NowPlayingSettings()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { isPresented = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

private struct NowPlayingSettings: View {
    @AppStorage(NowPlayingBridge.enabledKey) private var isEnabled = false
    @AppStorage(NowPlayingBridge.keepAirPodsFreeKey) private var keepAirPodsFree = true

    var body: some View {
        Form {
            Section {
                Toggle("Show in Control Center & Lock Screen", isOn: $isEnabled)
                Toggle("Keep AirPods free (experimental)", isOn: $keepAirPodsFree)
                    .disabled(!isEnabled)
            } footer: {
                Text("Shows the selected device in the system player, with artwork and controls, and lets the volume buttons control it even when locked. Replaces the Live Activity. To appear there, Tournesol plays silence while the other device plays, which can make AirPods switch to this device; “Keep AirPods free” routes that silence to the speaker to avoid it.")
            }
        }
    }
}
