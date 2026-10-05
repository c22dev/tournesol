//
//  ControlCenterSync.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import WidgetKit

final class ControlCenterSync {
    private let store: DeviceStore
    private var last: ControlSnapshot?

    init(store: DeviceStore) {
        self.store = store
        last = ControlSnapshot.load()
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let device = store.selected else { return }
        let snapshot = ControlSnapshot(
            deviceID: device.id,
            deviceName: device.displayName,
            deviceSymbol: device.info.kind.symbol,
            title: device.state.title,
            artist: device.state.artist,
            isPlaying: device.state.isPlaying
        )
        guard snapshot != last else { return }
        Self.publish(snapshot)
        last = snapshot
    }

    static func publish(_ snapshot: ControlSnapshot) {
        snapshot.save()
        ControlSnapshot.kinds.forEach { ControlCenter.shared.reloadControls(ofKind: $0) }
    }
}
