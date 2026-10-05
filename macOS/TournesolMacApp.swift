//
//  TournesolMacApp.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import IOKit.ps
import SwiftUI

@main
struct TournesolMacApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        Window("Tournesol", id: "main") {
            MacRootView(store: model.hub.store)
                .frame(minWidth: 760, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarRemote(store: model.hub.store)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView(model: model)
        }
    }
}

final class AppModel {
    static let shared = AppModel()
    let hub: Hub
    let mediaKeys: MediaKeyController
    let nowPlaying: NowPlayingBridge
    private var pairingPanel: NSPanel?
    private var lifecycle: [NSObjectProtocol] = []

    private init() {
        let info = DeviceInfo.current
        let transport = CompositeTransport([BLEPeripheral(localName: info.name), BLECentral()])
        hub = Hub(info: info, player: MusicAppSource(), transport: transport, pollInterval: .seconds(15))
        mediaKeys = MediaKeyController(store: hub.store)
        nowPlaying = NowPlayingBridge(store: hub.store)
        observePairing()
        let hub = hub
        hub.wantsDiscovery = NSApp?.isActive ?? true
        lifecycle = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hub.wantsDiscovery = name == NSApplication.didBecomeActiveNotification }
            }
        }
    }

    private func observePairing() {
        withObservationTracking {
            updatePairingPanel(for: hub.store.pairingPrompt)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePairing() }
        }
    }

    private func updatePairingPanel(for prompt: PairingPrompt?) {
        guard let prompt else {
            pairingPanel?.close()
            pairingPanel = nil
            return
        }
        if let panel = pairingPanel, (panel.contentView as? NSHostingView<PairingPanelContent>)?.rootView.prompt === prompt { return }
        pairingPanel?.close()

        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: PairingPanelContent(prompt: prompt))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 340))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        pairingPanel = panel
    }
}

private struct PairingPanelContent: View {
    let prompt: PairingPrompt

    var body: some View {
        PairingView(prompt: prompt)
            .frame(width: 420)
            .preferredColorScheme(.dark)
    }
}

extension DeviceInfo {
    static var current: DeviceInfo {
        DeviceInfo(id: DeviceIdentity.id, name: Host.current().localizedName ?? "Mac", kind: hasInternalBattery ? .macBook : .mac)
    }

    private static var hasInternalBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
