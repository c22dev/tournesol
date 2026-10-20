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
    /// What this device may do here. Guests only take part in a Jam.
    var access = Access.full
    /// The Jam this device is hosting, if it is.
    var jamAdvert: JamAdvert?

    enum Access {
        case full
        /// It hosts a Jam we joined as a guest: we can see what plays and add songs.
        case guestHost
        /// It joined our Jam as a guest: it can add songs.
        case guestMember
    }
    @ObservationIgnored var stateRevision = 0
    @ObservationIgnored private(set) var reportedState = PlaybackState.idle
    @ObservationIgnored private var playbackExpectation: (title: String?, expires: ContinuousClock.Instant)?
    @ObservationIgnored private var volumeIntent: (value: Double, expires: ContinuousClock.Instant)?
    @ObservationIgnored private var settingIntents: [String: (apply: (inout PlaybackState) -> Void, holds: (PlaybackState) -> Bool, expires: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var queuedVolume: Double?
    @ObservationIgnored private var volumeSender: Task<Void, Never>?

    @ObservationIgnored var onCommand: (Command) -> Void = { _ in }
    @ObservationIgnored var onRefresh: () -> Void = {}
    /// Nil when the queue couldn't be read, as opposed to being empty.
    @ObservationIgnored var onFetchQueue: () async -> [TrackReference]? = { [] }

    func upcomingTracks() async -> [TrackReference]? { await onFetchQueue() }

    var hasEditableQueue: Bool { access == .full }

    init(info: DeviceInfo, isLocal: Bool) {
        id = info.id
        self.info = info
        self.isLocal = isLocal
        isPaired = isLocal
    }

    var isControllable: Bool { isLocal || (isPaired && access != .guestMember) }

    var displayName: String {
        isLocal ? "This \(info.kind.displayName)" : info.name
    }

    func send(_ command: Command) {
        // the host of a Jam we're a guest in only takes songs to add
        if access == .guestHost {
            switch command {
            case .enqueue, .enqueueAll: break
            default: return
            }
        }
        if case .setVolume(let volume) = command {
            return setVolume(volume)
        }
        apply(command)
        onCommand(command)
    }

    func setVolume(_ volume: Double) {
        guard state.volume != nil, access != .guestHost else { return }
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
        // A changed setting shows at once; the device's older report must not flip it back before the change lands.
        for (key, intent) in settingIntents {
            if ContinuousClock.now > intent.expires || intent.holds(incoming) {
                settingIntents[key] = nil
            } else {
                intent.apply(&incoming)
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

    private func hold(_ key: String, _ apply: @escaping (inout PlaybackState) -> Void, _ holds: @escaping (PlaybackState) -> Bool) {
        settingIntents[key] = (apply, holds, .now + .seconds(3))
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
        case .loadTrack(let track, let position, _):
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
        case .setShuffle(let on):
            hold("shuffle", { $0.shuffle = on }, { $0.shuffle == on })
            next.shuffle = on
        case .setRepeat(let mode):
            hold("repeat", { $0.repeatMode = mode }, { $0.repeatMode == mode })
            next.repeatMode = mode
        case .setLiked(let liked):
            hold("liked", { $0.isLiked = liked }, { $0.isLiked == liked })
            next.isLiked = liked
        case .setAirPlay(let ids):
            let selection = { (state: inout PlaybackState) in
                state.airPlay = state.airPlay?.map { AirPlayDevice(name: $0.name, kind: $0.kind, isSelected: ids.contains($0.id), id: $0.id) }
            }
            hold("airplay", selection, { Set($0.airPlay?.filter(\.isSelected).map(\.id) ?? []) == Set(ids) })
            selection(&next)
        case .next, .previous, .enqueue, .enqueueAll, .setQueue: return
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
final class JamPrompt: Identifiable {
    enum Kind {
        /// Someone invites this device into their Jam.
        case invite
        /// Someone asks to join this device's Jam.
        case request
    }

    let id = UUID()
    let kind: Kind
    let deviceName: String
    let deviceSymbol: String
    let isGuest: Bool

    @ObservationIgnored var respond: (_ accept: Bool, _ playsHere: Bool) -> Void = { _, _ in }

    init(kind: Kind, deviceName: String, deviceSymbol: String, isGuest: Bool) {
        self.kind = kind
        self.deviceName = deviceName
        self.deviceSymbol = deviceSymbol
        self.isGuest = isGuest
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
    var jam: JamSession?
    /// An invitation to join a Jam, or someone asking to join ours.
    var jamPrompt: JamPrompt?

    @ObservationIgnored var onPair: (RemoteDevice) -> Void = { _ in }
    @ObservationIgnored var onTransfer: (RemoteDevice, RemoteDevice) -> Void = { _, _ in }
    @ObservationIgnored var onForget: (String) -> Void = { _ in }
    @ObservationIgnored var onStartJam: () -> Void = {}
    @ObservationIgnored var onLeaveJam: () -> Void = {}
    @ObservationIgnored var onInviteToJam: (RemoteDevice) -> Void = { _ in }
    @ObservationIgnored var onJoinJam: (RemoteDevice, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onSetJamPlays: (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onPlayOnAll: (Bool) -> Void = { _ in }
    /// Nil where there's no microphone to tune with.
    @ObservationIgnored var onTuneJam: (() async -> String)?

    var selected: RemoteDevice? {
        controllable.first { $0.id == selectedID } ?? devices.first(where: \.isLocal)
    }

    var controllable: [RemoteDevice] {
        devices.filter(\.isControllable)
    }

    var remotes: [RemoteDevice] {
        devices.filter { !$0.isLocal && $0.isPaired && $0.access == .full }
    }

    /// Devices nearby hosting a Jam this one isn't in.
    var nearbyJams: [RemoteDevice] {
        devices.filter { !$0.isLocal && $0.isConnected && $0.jamAdvert != nil && $0.jamAdvert?.id != jam?.id }
    }

    var unpaired: [RemoteDevice] {
        devices.filter { !$0.isLocal && !$0.isPaired }
    }

    func transferTargets(from source: RemoteDevice) -> [RemoteDevice] {
        controllable.filter { $0.id != source.id && $0.isConnected && $0.access == .full }
    }

    func device(id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }
}
