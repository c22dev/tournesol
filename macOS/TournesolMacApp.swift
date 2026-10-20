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
        .commands {
            CommandMenu("Playback") {
                PlaybackMenu(store: model.hub.store)
            }
        }

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

private struct PlaybackMenu: View {
    let store: DeviceStore

    var body: some View {
        let device = store.selected
        let hasTrack = device?.state.hasTrack == true
        // Space is handled by the key monitor in AppDelegate: a menu item can't take a bare key
        Button(device?.state.isPlaying == true ? "Pause" : "Play") { device?.send(.togglePlayPause) }
            .disabled(!hasTrack)
        Button("Next") { device?.send(.next) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!hasTrack)
        Button("Previous") { device?.send(.previous) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!hasTrack)
        Divider()
        Button("Skip Forward 10 Seconds") { skip(10) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!hasTrack)
        Button("Skip Back 10 Seconds") { skip(-10) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!hasTrack)
        Divider()
        Button("Increase Volume") { device?.stepVolume(1) }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(device?.state.volume == nil)
        Button("Decrease Volume") { device?.stepVolume(-1) }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(device?.state.volume == nil)
        Divider()
        Button("Search Apple Music…") { NotificationCenter.default.post(name: .showSearch, object: nil) }
            .keyboardShortcut("f")
            .disabled(device?.isConnected != true)
        Button("Up Next") { NotificationCenter.default.post(name: .showQueue, object: nil) }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(device?.isConnected != true)
    }

    private func skip(_ seconds: TimeInterval) {
        guard let device = store.selected else { return }
        let state = device.state
        device.send(.seek(min(max(0, state.elapsed(at: .now) + seconds), state.duration)))
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
    private var spaceMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // a menu item can't take a bare Space, so catch it here unless a text field has focus
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            AppModel.shared.hub.store.selected?.send(.togglePlayPause)
            return nil
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        guard !launchedAtLogin else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let store = AppModel.shared.hub.store
        guard let device = store.selected, device.state.hasTrack else { return nil }
        let menu = NSMenu()
        for (title, command) in [(device.state.isPlaying ? "Pause" : "Play", Command.togglePlayPause), ("Next", .next), ("Previous", .previous)] {
            let item = NSMenuItem(title: title, action: #selector(sendDockCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DockCommand(command: command)
            menu.addItem(item)
        }
        return menu
    }

    private final class DockCommand: NSObject {
        let command: Command
        init(command: Command) { self.command = command }
    }

    @objc private func sendDockCommand(_ item: NSMenuItem) {
        guard let dock = item.representedObject as? DockCommand else { return }
        AppModel.shared.hub.store.selected?.send(dock.command)
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
}

final class AppModel {
    static let shared = AppModel()
    let hub: Hub
    let cider: CiderSource
    let mediaKeys: MediaKeyController
    let nowPlaying: NowPlayingBridge
    private var pairingPanel: NSPanel?
    private var lifecycle: [NSObjectProtocol] = []

    private init() {
        let info = DeviceInfo.current
        let transport = CompositeTransport([BLEPeripheral(localName: info.name), BLECentral(), LANTransport(localID: info.id, activationNotifications: [NSApplication.didBecomeActiveNotification])])
        let player = MacPlayer()
        cider = player.cider
        hub = Hub(info: info, player: player, transport: transport, pollInterval: .seconds(15))
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "jamSelfTest") { Task { [hub] in await JamSelfTest.run(hub: hub) } }
        #endif
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

#if DEBUG
import OSLog

/// Starts a Jam with a connected iPhone and logs how well it stays in step. Launch with `-jamSelfTest YES`.
/// This Mac plays a song muted; the phone plays it out loud.
enum JamSelfTest {
    private static let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "JamTest")
    private static func say(_ text: String) { log.info("JAMTEST \(text, privacy: .public)") }

    private static func setMusicVolume(_ volume: Int) {
        _ = NSAppleScript(source: "tell application \"Music\" to set sound volume to \(volume)")?.executeAndReturnError(nil)
    }

    static func run(hub: Hub) async {
        let store = hub.store
        var phone: RemoteDevice?
        for _ in 0..<150 {
            phone = store.remotes.first { $0.isConnected && $0.info.kind == .iPhone }
            if phone != nil { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let phone else { return say("no connected iPhone") }
        say("found \(phone.info.name)")

        setMusicVolume(0)
        hub.local.send(.play)
        for _ in 0..<40 where !hub.local.state.isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
        say("leader playing: \(hub.local.state.isPlaying), \(hub.local.state.title ?? "nil")")

        store.onStartJam()
        for _ in 0..<30 where store.jam?.members.contains(where: { $0.id == phone.id }) != true { try? await Task.sleep(for: .milliseconds(500)) }
        say("joined as a remote: \(store.jam?.members.contains(where: { $0.id == phone.id }) == true), now asking it to play")
        store.onSetJamPlays(phone.id, true)
        let started = ContinuousClock.now
        func seconds() -> Int { Int((ContinuousClock.now - started) / .seconds(1)) }
        func report(_ label: String) {
            let reported = store.jam?.drifts[phone.id].map { String(format: "%+.3f", $0) } ?? "none yet"
            let now = Date.now
            let independent = phone.state.isPlaying && hub.local.state.isPlaying
                ? String(format: "%+.3f", phone.state.elapsed(at: now) - hub.local.state.elapsed(at: now)) : "n/a"
            say("t=\(seconds()) \(label): phone \(phone.state.title ?? "nil") playing=\(phone.state.isPlaying) | member's own drift \(reported) s | independent diff \(independent) s | members \(store.jam?.members.count ?? 0)")
        }
        if UserDefaults.standard.bool(forKey: "jamTuneTest") {
            setMusicVolume(30)
            try? await Task.sleep(for: .seconds(12))
            report("before tuning")
            for round in 1...2 {
                let result = await store.onTuneJam?() ?? "unavailable"
                say("tune \(round): \(result.replacingOccurrences(of: "\n", with: " / "))")
                try? await Task.sleep(for: .seconds(10))
                report("after tune \(round)")
            }
            store.onLeaveJam()
            hub.local.send(.pause)
            return say("done, jam left: \(store.jam == nil)")
        }
        for step in 1...90 {
            try? await Task.sleep(for: .seconds(1))
            if step == 34 { hub.local.send(.pause); say("t=\(seconds()) leader paused") }
            if step == 44 { report("after pause (expect phone paused)"); hub.local.send(.play); say("t=\(seconds()) leader resumed") }
            if step == 62 { hub.local.send(.next); say("t=\(seconds()) leader skipped to the next song") }
            if step % 5 == 0 { report("steady") }
        }
        store.onLeaveJam()
        hub.local.send(.pause)
        setMusicVolume(100)
        say("done, jam left: \(store.jam == nil)")
    }
}
#endif
