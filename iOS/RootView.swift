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
                        .toolbar { RenameButton(model: model) }
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
