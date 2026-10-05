//
//  LiveActivityController.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import ActivityKit
import UIKit

final class LiveActivityController {
    private let store: DeviceStore
    private var activity: Activity<RemoteActivityAttributes>?
    private var lastContent: RemoteActivityAttributes.ContentState?
    private var observer: NSObjectProtocol?

    init(store: DeviceStore) {
        self.store = store
        let existing = Activity<RemoteActivityAttributes>.activities
        activity = existing.first
        existing.dropFirst().forEach { Self.end(id: $0.id) }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private var focused: RemoteDevice? {
        if let selected = store.selected, !selected.isLocal { return selected }
        if let activity, let device = store.device(id: activity.attributes.deviceID), device.isPaired { return device }
        return store.remotes.first { $0.state.isPlaying }
    }

    private func sync() {
        let isPlayingHere = store.devices.contains { $0.isLocal && $0.state.isPlaying }
        guard !isPlayingHere, let device = focused, device.state.hasTrack else { return end() }
        let content = RemoteActivityAttributes.ContentState(device: device)

        if let activity, activity.attributes.deviceID == device.id {
            guard content != lastContent else { return }
            lastContent = content
            let id = activity.id
            Task { await Self.update(id: id, content: content) }
            return
        }

        guard UIApplication.shared.applicationState == .active, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = RemoteActivityAttributes(deviceID: device.id, deviceName: device.info.name, deviceSymbol: device.info.kind.symbol)
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: nil))
        lastContent = content
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastContent = nil
        Self.end(id: activity.id)
    }

    private nonisolated static func update(id: String, content: RemoteActivityAttributes.ContentState) async {
        let activity = Activity<RemoteActivityAttributes>.activities.first { $0.id == id }
        await activity?.update(ActivityContent(state: content, staleDate: nil))
    }

    nonisolated static func flipPlayback(deviceID: String) async -> RemoteActivityAttributes.ContentState? {
        guard let activity = Activity<RemoteActivityAttributes>.activities.first(where: { $0.attributes.deviceID == deviceID }) else { return nil }
        let original = activity.content.state
        let now = Date.now
        var next = original
        if original.isPlaying {
            next.elapsed = min(original.duration, original.elapsed + now.timeIntervalSince(original.timestamp))
        }
        next.timestamp = now
        next.isPlaying.toggle()
        await activity.update(ActivityContent(state: next, staleDate: nil))
        return original
    }

    nonisolated static func restore(_ content: RemoteActivityAttributes.ContentState, deviceID: String) async {
        let activity = Activity<RemoteActivityAttributes>.activities.first { $0.attributes.deviceID == deviceID }
        await activity?.update(ActivityContent(state: content, staleDate: nil))
    }

    private nonisolated static func end(id: String) {
        Task {
            let activity = Activity<RemoteActivityAttributes>.activities.first { $0.id == id }
            await activity?.end(nil, dismissalPolicy: .immediate)
        }
    }
}

extension RemoteActivityAttributes.ContentState {
    init(device: RemoteDevice) {
        let state = device.state
        self.init(
            title: state.title ?? "Not Playing",
            artist: state.artist ?? "",
            isPlaying: state.isPlaying,
            elapsed: state.elapsed,
            duration: state.duration,
            timestamp: state.timestamp,
            artworkID: device.artworkKey,
            outputName: state.output?.kind == .builtIn ? nil : state.output?.name,
            outputSymbol: state.output?.kind == .builtIn ? nil : state.output?.symbol,
            tint: device.tint,
            isConnected: device.isConnected
        )
    }
}
