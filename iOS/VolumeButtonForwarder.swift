//
//  VolumeButtonForwarder.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import OSLog
import UIKit

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "VolumeButtons")

final class VolumeButtonForwarder {
    private enum Mode {
        case off, foreground, background
    }

    private static let baseline = 0.5

    private let store: DeviceStore
    private let volume = VolumeService.shared
    private let onFocusChange: (String?) -> Void
    private var mode = Mode.off
    private var isForeground = UIApplication.shared.applicationState == .active
    private var savedVolume: Double?
    private var observers: [NSObjectProtocol] = []

    init(store: DeviceStore, onFocusChange: @escaping (String?) -> Void) {
        self.store = store
        self.onFocusChange = onFocusChange
        volume.onButtonPress = { [weak self] steps in self?.forward(steps) ?? false }

        let transitions: [(Notification.Name, Bool)] = [
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.didEnterBackgroundNotification, false),
        ]
        observers = transitions.map { name, foreground in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isForeground = foreground
                    self?.update()
                }
            }
        }
        observe()
    }

    private var target: RemoteDevice? {
        guard let device = store.selected, !device.isLocal, device.isConnected, device.state.volume != nil else { return nil }
        return device
    }

    private var isPlayingHere: Bool {
        store.devices.contains { $0.isLocal && $0.state.isPlaying }
    }

    private func observe() {
        withObservationTracking {
            _ = (target?.id, isPlayingHere)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let desired: Mode = target == nil || isPlayingHere ? .off : (isForeground ? .foreground : .background)
        guard desired != mode else { return }
        log.debug("mode \(String(describing: desired), privacy: .public) target \(self.target?.info.name ?? "none", privacy: .public)")
        mode = desired

        switch desired {
        case .off:
            if let savedVolume { volume.set(savedVolume) }
            savedVolume = nil
            onFocusChange(nil)
        case .foreground:
            pin()
            onFocusChange(nil)
        case .background:
            pin()
            onFocusChange(NowPlayingBridge.isMirroring ? nil : target?.id)
        }
    }

    private func pin() {
        if savedVolume == nil { savedVolume = volume.current }
        if abs(volume.current - Self.baseline) > 0.001 { volume.set(Self.baseline) }
    }

    private func forward(_ steps: Int) -> Bool {
        guard mode != .off, let target else { return false }
        target.stepVolume(steps)
        volume.set(Self.baseline)
        return true
    }
}
