//
//  RemoteDevice.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

@Observable
final class RemoteDevice: Identifiable {
    let id: String
    let isLocal: Bool
    var info: DeviceInfo
    var state = PlaybackState.idle
    var artwork: PlatformImage?
    var artworkKey: String?
    var tint: RGB?
    var isConnected = true
    var isPaired: Bool
    @ObservationIgnored var stateRevision = 0
    @ObservationIgnored private(set) var reportedState = PlaybackState.idle
    @ObservationIgnored private var playbackExpectation: (title: String?, expires: ContinuousClock.Instant)?
    @ObservationIgnored private var volumeIntent: (value: Double, expires: ContinuousClock.Instant)?
    @ObservationIgnored private var queuedVolume: Double?
    @ObservationIgnored private var volumeSender: Task<Void, Never>?

    @ObservationIgnored var onCommand: (Command) -> Void = { _ in }
    @ObservationIgnored var onRefresh: () -> Void = {}

    init(info: DeviceInfo, isLocal: Bool) {
        id = info.id
        self.info = info
        self.isLocal = isLocal
        isPaired = isLocal
    }

    var isControllable: Bool { isLocal || isPaired }

    var displayName: String {
        isLocal ? "This \(info.kind.displayName)" : info.name
    }

    func send(_ command: Command) {
        if case .setVolume(let volume) = command {
            return setVolume(volume)
        }
        apply(command)
        onCommand(command)
    }

    func setVolume(_ volume: Double) {
        guard state.volume != nil else { return }
        let volume = min(1, max(0, volume))
        volumeIntent = (volume, .now + .seconds(1.5))
        state.volume = volume
        queuedVolume = volume
        guard volumeSender == nil else { return }
        volumeSender = Task { [weak self] in
            while let self, let next = queuedVolume {
                queuedVolume = nil
                onCommand(.setVolume(next))
                try? await Task.sleep(for: .milliseconds(60))
            }
            self?.volumeSender = nil
        }
    }

    func stepVolume(_ steps: Int) {
        guard let volume = state.volume else { return }
        setVolume(((volume * 16).rounded() + Double(steps)) / 16)
    }

    func expectPlayback(of track: TrackReference) {
        playbackExpectation = (track.title, .now + .seconds(10))
    }

    func clearPlaybackExpectation() {
        playbackExpectation = nil
        state = reportedState
    }

    func receive(_ incoming: PlaybackState) {
        reportedState = incoming
        var incoming = incoming
        if let expectation = playbackExpectation {
            if ContinuousClock.now > expectation.expires || (incoming.isPlaying && TrackMatcher.sameSong(incoming.title, expectation.title)) {
                playbackExpectation = nil
            } else {
                let held = incoming
                incoming = state
                incoming.volume = held.volume
                incoming.output = held.output
            }
        }
        if let intent = volumeIntent {
            if ContinuousClock.now > intent.expires || abs((incoming.volume ?? -1) - intent.value) < 0.02 {
                volumeIntent = nil
            } else {
                incoming.volume = intent.value
            }
        }
        state = incoming
    }

    func refresh() {
        onRefresh()
    }

    func setArtwork(_ data: Data?, key: String?) {
        let image = data.flatMap(PlatformImage.init(data:))
        artworkKey = image == nil ? nil : key
        withAnimation(.smooth(duration: 0.45)) {
            artwork = image
            tint = image?.averageRGB()?.normalized()
        }
    }

    private func apply(_ command: Command) {
        let now = Date.now
        var next = state
        next.elapsed = state.elapsed(at: now)
        next.timestamp = now
        switch command {
        case .play: next.isPlaying = true
        case .pause: next.isPlaying = false
        case .togglePlayPause: next.isPlaying.toggle()
        case .seek(let position): next.elapsed = position
        case .setVolume: return
        case .loadTrack(let track, let position):
            next.title = track.title
            next.artist = track.artist
            next.album = track.album
            next.duration = track.duration
            next.catalogID = track.catalogID
            next.elapsed = position
            next.isPlaying = true
        case .startLoaded:
            next.isPlaying = true
        case .handOff:
            next.isPlaying = false
        case .release:
            next = PlaybackState(volume: state.volume, output: state.output)
        case .next, .previous: return
        }
        withAnimation(.snappy) { state = next }
    }
}

@Observable
final class PairingPrompt: Identifiable {
    enum Phase {
        case exchanging, comparing, waitingForPeer, paired, cancelled
    }

    let id = UUID()
    let deviceName: String
    let deviceSymbol: String
    var code: String?
    var phase = Phase.exchanging

    @ObservationIgnored var respond: (Bool) -> Void = { _ in }

    init(deviceName: String, deviceSymbol: String) {
        self.deviceName = deviceName
        self.deviceSymbol = deviceSymbol
    }
}

@Observable
final class TransferStatus {
    enum Phase {
        case moving, failed
    }

    let targetName: String
    var phase = Phase.moving

    init(targetName: String) {
        self.targetName = targetName
    }
}

@Observable
final class DeviceStore {
    var devices: [RemoteDevice] = []
    var selectedID: String? {
        didSet {
            if !isAutoSelecting, selectedID != oldValue { lastManualSelection = .now }
        }
    }
    @ObservationIgnored private var isAutoSelecting = false
    @ObservationIgnored private(set) var lastManualSelection: ContinuousClock.Instant?

    func autoSelect(_ id: String) {
        guard selectedID != id else { return }
        isAutoSelecting = true
        selectedID = id
        isAutoSelecting = false
    }
    var pairingPrompt: PairingPrompt?
    var transfer: TransferStatus?

    @ObservationIgnored var onPair: (RemoteDevice) -> Void = { _ in }
    @ObservationIgnored var onTransfer: (RemoteDevice, RemoteDevice) -> Void = { _, _ in }
    @ObservationIgnored var onForget: (String) -> Void = { _ in }

    var selected: RemoteDevice? {
        controllable.first { $0.id == selectedID } ?? devices.first(where: \.isLocal)
    }

    var controllable: [RemoteDevice] {
        devices.filter(\.isControllable)
    }

    var remotes: [RemoteDevice] {
        devices.filter { !$0.isLocal && $0.isPaired }
    }

    var unpaired: [RemoteDevice] {
        devices.filter { !$0.isLocal && !$0.isPaired }
    }

    func transferTargets(from source: RemoteDevice) -> [RemoteDevice] {
        controllable.filter { $0.id != source.id && $0.isConnected }
    }

    func device(id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }
}
