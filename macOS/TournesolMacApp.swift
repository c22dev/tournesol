//
//  TournesolMacApp.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import IOKit.ps
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let openMainWindow = Notification.Name("ch.cclerc.Tournesol.openMainWindow")
}

@main
struct TournesolMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Tournesol", id: "main") {
            MacRootView(store: model.hub.store)
                .frame(minWidth: 760, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarRemote(store: model.hub.store)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView(model: model)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "sun.max.fill")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.registerOnFirstLaunch()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        guard !launchedAtLogin else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        return false
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }

    static func registerOnFirstLaunch() {
        let key = "registeredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
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
