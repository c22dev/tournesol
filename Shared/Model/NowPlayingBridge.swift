//
//  NowPlayingBridge.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import MediaPlayer
import OSLog

nonisolated private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "NowPlaying")

final class NowPlayingBridge {
    static let enabledKey = "nowPlayingMode"
    static let keepAirPodsFreeKey = "nowPlayingKeepAirPodsFree"
    static private(set) var isMirroring = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let store: DeviceStore
    private var mirrored: RemoteDevice?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var publishedArtworkKey: String?
    private var defaultsObserver: NSObjectProtocol?
    #if os(iOS)
    private let silence = SilentAudio()
    #endif

    init(store: DeviceStore) {
        self.store = store
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
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

    private var candidate: RemoteDevice? {
        guard Self.isEnabled, let device = store.selected, !device.isLocal, device.isConnected, device.state.hasTrack else { return nil }
        #if os(iOS)
        if store.devices.contains(where: { $0.isLocal && $0.state.isPlaying }) { return nil }
        #endif
        return device
    }

    private func sync() {
        guard let device = candidate else { return stop() }
        if mirrored !== device {
            log.debug("mirroring \(device.info.name, privacy: .public)")
            mirrored = device
            publishedArtworkKey = nil
            registerCommands()
        }
        Self.isMirroring = true
        publish(device)

        #if os(iOS)
        if device.state.isPlaying {
            silence.start(keepAirPodsFree: UserDefaults.standard.bool(forKey: Self.keepAirPodsFreeKey))
        } else {
            silence.stop()
        }
        #endif
    }

    private func publish(_ device: RemoteDevice) {
        let state = device.state
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title ?? "",
            MPMediaItemPropertyArtist: state.artist ?? "",
            MPMediaItemPropertyAlbumTitle: state.album ?? "",
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed(at: .now),
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        let center = MPNowPlayingInfoCenter.default()
        if let image = device.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork], publishedArtworkKey == device.artworkKey {
            info[MPMediaItemPropertyArtwork] = existing
        }
        publishedArtworkKey = device.artworkKey
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = state.isPlaying ? .playing : .paused
        #endif
    }

    private func registerCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping (RemoteDevice, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let device = self?.mirrored else { return .noActionableNowPlayingItem }
                    action(device, event)
                    return .success
                }
            }
            commandTargets.append((command, target))
        }
        on(center.playCommand) { device, _ in device.send(.play) }
        on(center.pauseCommand) { device, _ in device.send(.pause) }
        on(center.togglePlayPauseCommand) { device, _ in device.send(.togglePlayPause) }
        on(center.nextTrackCommand) { device, _ in device.send(.next) }
        on(center.previousTrackCommand) { device, _ in device.send(.previous) }
        on(center.changePlaybackPositionCommand) { device, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { device.send(.seek(event.positionTime)) }
        }
    }

    private func stop() {
        guard Self.isMirroring || !commandTargets.isEmpty else { return }
        log.debug("stopped mirroring")
        Self.isMirroring = false
        mirrored = nil
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
        #if os(iOS)
        silence.stop()
        #endif
    }
}
