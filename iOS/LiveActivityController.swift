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
    private var tokens = PushTokens(environment: PushRelay.environment)
    private var sharedTokens: PushTokens?
    private var defaultsObserver: NSObjectProtocol?
    private var tokenTask: Task<Void, Never>?
    var onTokens: ((PushTokens) -> Void)?

    init(store: DeviceStore) {
        self.store = store
        let existing = Activity<RemoteActivityAttributes>.activities
        activity = existing.first
        existing.dropFirst().forEach { Self.end(id: $0.id) }
        if let activity { watchTokens(of: activity) }
        Task { [weak self] in
            await Self.startTokens { token in self?.publish { $0.startToken = token } }
        }
        Task { [weak self] in
            await Self.newActivities { id in self?.adopt(id) }
        }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish()
                self?.sync()
            }
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

    private func publish(_ change: (inout PushTokens) -> Void = { _ in }) {
        change(&tokens)
        let effective = NowPlayingBridge.isEnabled ? PushTokens(environment: tokens.environment) : tokens
        guard effective != sharedTokens else { return }
        sharedTokens = effective
        onTokens?(effective)
    }

    private func adopt(_ id: String) {
        guard activity?.id != id, let adopted = Activity<RemoteActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if let activity { Self.end(id: activity.id) }
        activity = adopted
        lastContent = nil
        watchTokens(of: adopted)
        sync()
    }

    private func watchTokens(of activity: Activity<RemoteActivityAttributes>) {
        let id = activity.id
        let deviceID = activity.attributes.deviceID
        tokenTask?.cancel()
        publish { $0.activityTokens = [:] }
        tokenTask = Task { [weak self] in
            await Self.activityTokens(id: id) { token in
                self?.publish { $0.activityTokens = token.map { [deviceID: $0] } ?? [:] }
            }
        }
    }

    private func sync() {
        let isPlayingHere = store.devices.contains { $0.isLocal && $0.state.isPlaying }
        if isPlayingHere || NowPlayingBridge.isEnabled { return end() }
        guard let device = focused, device.state.hasTrack else {
            if let activity, store.device(id: activity.attributes.deviceID) == nil { return }
            return end()
        }
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
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: nil), pushType: .token)
        lastContent = content
        if let activity { watchTokens(of: activity) }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastContent = nil
        tokenTask?.cancel()
        publish { $0.activityTokens = [:] }
        Self.end(id: activity.id)
    }

    private nonisolated static func startTokens(_ deliver: @escaping @MainActor (String) -> Void) async {
        for await data in Activity<RemoteActivityAttributes>.pushToStartTokenUpdates {
            await deliver(data.hexString)
        }
    }

    private nonisolated static func newActivities(_ deliver: @escaping @MainActor (String) -> Void) async {
        for await activity in Activity<RemoteActivityAttributes>.activityUpdates {
            await deliver(activity.id)
        }
    }

    private nonisolated static func activityTokens(id: String, deliver: @escaping @Sendable @MainActor (String?) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                guard let activity = Activity<RemoteActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
                for await data in activity.pushTokenUpdates {
                    await deliver(data.hexString)
                }
            }
            group.addTask {
                guard let activity = Activity<RemoteActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    await deliver(nil)
                }
            }
        }
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

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
