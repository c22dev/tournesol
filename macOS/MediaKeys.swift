//
//  MediaKeys.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppKit
import ApplicationServices
import SwiftUI

nonisolated enum MediaKey: Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    init?(keyCode: Int) {
        switch keyCode {
        case 16: self = .playPause
        case 17, 19: self = .next
        case 18, 20: self = .previous
        case 0: self = .volumeUp
        case 1: self = .volumeDown
        case 7: self = .mute
        default: return nil
        }
    }

    var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
}

final class MediaKeyTap {
    var handler: ((MediaKey, Bool) -> Bool)?
    private var port: CFMachPort?

    var isRunning: Bool { port != nil }

    func start() -> Bool {
        guard port == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { tap.reenable() }
                return Unmanaged.passUnretained(event)
            }

            guard let (key, isDown) = MediaKeyTap.parse(event) else { return Unmanaged.passUnretained(event) }
            let swallow = MainActor.assumeIsolated { tap.handler?(key, isDown) ?? false }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        return true
    }

    private func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private nonisolated static func parse(_ event: CGEvent) -> (MediaKey, Bool)? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else { return nil }
        let data = nsEvent.data1
        let flags = data & 0xFFFF
        guard let key = MediaKey(keyCode: (data & 0xFFFF_0000) >> 16) else { return nil }
        return (key, (flags & 0xFF00) >> 8 == 0xA)
    }
}

final class MediaKeyController {
    static let enabledKey = "mediaKeysEnabled"
    static let volumeKey = "volumeKeysEnabled"

    private let store: DeviceStore
    private let tap = MediaKeyTap()
    private let hud = MediaKeyHUD()
    private var retryTask: Task<Void, Never>?
    private var volumesBeforeMute: [String: Double] = [:]

    init(store: DeviceStore) {
        self.store = store
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.volumeKey: true])
        tap.handler = { [weak self] key, isDown in self?.handle(key, isDown: isDown) ?? false }
        if AXIsProcessTrusted() {
            startWhenTrusted()
        } else {
            requestAccess()
        }
    }

    func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        startWhenTrusted()
    }

    private func startWhenTrusted() {
        guard !tap.start(), retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if tap.start() {
                    retryTask = nil
                    return
                }
            }
        }
    }

    private func handle(_ key: MediaKey, isDown: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.enabledKey),
              !key.isVolume || defaults.bool(forKey: Self.volumeKey),
              let device = store.selected, !device.isLocal, device.isConnected
        else { return false }
        guard isDown else { return true }

        let symbol: String
        switch key {
        case .playPause:
            device.send(.togglePlayPause)
            symbol = device.state.isPlaying ? "play.fill" : "pause.fill"
        case .next:
            device.send(.next)
            symbol = "forward.fill"
        case .previous:
            device.send(.previous)
            symbol = "backward.fill"
        case .volumeUp:
            device.stepVolume(1)
            symbol = "speaker.wave.3.fill"
        case .volumeDown:
            device.stepVolume(-1)
            symbol = device.state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill"
        case .mute:
            let volume = device.state.volume ?? 0
            if volume > 0 {
                volumesBeforeMute[device.id] = volume
                device.setVolume(0)
                symbol = "speaker.slash.fill"
            } else {
                device.setVolume(volumesBeforeMute.removeValue(forKey: device.id) ?? 0.5)
                symbol = "speaker.wave.2.fill"
            }
        }
        hud.show(device: device, symbol: symbol, showsVolume: key.isVolume)
        return true
    }
}

final class MediaKeyHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(device: RemoteDevice, symbol: String, showsVolume: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDView(device: device, symbol: symbol, showsVolume: showsVolume))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 120))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

private struct HUDView: View {
    let device: RemoteDevice
    let symbol: String
    let showsVolume: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Label(device.info.name, systemImage: device.info.kind.symbol)
                    .font(.headline)
                if showsVolume, let volume = device.state.volume {
                    ProgressView(value: volume)
                        .tint(.white)
                        .frame(width: 180)
                } else {
                    Text(device.state.title ?? "Not Playing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 260, alignment: .leading)
        .glassEffect(.regular.tint((device.tint ?? .sunflower).color.opacity(0.3)), in: .capsule)
        .padding(20)
        .preferredColorScheme(.dark)
    }
}
