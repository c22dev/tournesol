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

    /// Unset counts as on, like the toggle in Settings.
    static var keepAirPodsFree: Bool { UserDefaults.standard.object(forKey: keepAirPodsFreeKey) as? Bool ?? true }

    private let store: DeviceStore
    private var mirrored: RemoteDevice?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var publishedArtworkKey: String?
    private var defaultsObserver: NSObjectProtocol?
    #if os(iOS)
    private let silence = SilentAudio()
    #else
    /// macOS reads "playing" as the Mac wanting the AirPods and asks for them. Right after a remote starts they are still on their way
    /// to it, so the Mac only says "playing" once the remote has been playing for a few seconds.
    private static let playingDelay: Duration = .seconds(3)
    private var playingSince: ContinuousClock.Instant?
    private var playingTask: Task<Void, Never>?
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
        // A Jam that plays here has this device's own audio running, which the silent audio would only disturb.
        if store.jam?.playsHere == true { return nil }
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
            #if os(macOS)
            playingSince = nil
            #endif
            registerCommands()
        }
        Self.isMirroring = true
        #if os(macOS)
        trackPlaying(of: device)
        #endif
        publish(device)

        #if os(iOS)
        if device.state.isPlaying {
            if silence.start(keepAirPodsFree: Self.keepAirPodsFree) {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    if let device = self?.mirrored { self?.publish(device) }
                }
            }
        } else {
            silence.pause()
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
            info[MPMediaItemPropertyArtwork] = Self.artwork(for: image)
        } else if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork], let published = publishedArtworkKey, published == device.artworkKey {
            info[MPMediaItemPropertyArtwork] = existing
        }
        publishedArtworkKey = device.artworkKey
        center.nowPlayingInfo = info
        #if os(macOS)
        let settled = playingSince.map { ContinuousClock.now - $0 >= Self.playingDelay } ?? false
        center.playbackState = state.isPlaying && settled ? .playing : .paused
        #endif
    }

    #if os(macOS)
    private func trackPlaying(of device: RemoteDevice) {
        guard device.state.isPlaying else {
            playingSince = nil
            playingTask?.cancel()
            playingTask = nil
            return
        }
        guard playingSince == nil else { return }
        playingSince = .now
        playingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.playingDelay)
            guard !Task.isCancelled, let self, let device = mirrored else { return }
            publish(device)
        }
    }
    #endif

    private nonisolated static func artwork(for image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
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
        playingSince = nil
        playingTask?.cancel()
        playingTask = nil
        #endif
        #if os(iOS)
        silence.stop()
        #endif
    }
}
