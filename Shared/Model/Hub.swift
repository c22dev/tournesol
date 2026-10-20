//
//  Hub.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import CryptoKit
import OSLog
import SwiftUI

nonisolated private let hubLog = Logger(subsystem: "ch.cclerc.Tournesol", category: "Hub")

protocol LocalPlayer: AnyObject {
    var state: PlaybackState { get }
    var artwork: Artwork? { get }
    var onChange: (() -> Void)? { get set }
    func perform(_ command: Command)
    func refresh()
    func prepare(_ track: TrackReference)
    func upcomingTracks() async -> [TrackReference]
}

nonisolated enum Medium: Sendable {
    case bluetooth, wifi
}

protocol MessageTransport: AnyObject {
    var onConnect: ((UUID) -> Void)? { get set }
    var onDisconnect: ((UUID) -> Void)? { get set }
    var onMessage: ((Envelope, UUID) -> Void)? { get set }
    func send(_ message: Envelope, to peer: UUID, lane: Lane)
    /// Higher wins when a device is reachable over more than one link. Bluetooth is preferred: it costs the least power.
    func priority(of peer: UUID) -> Int
    func medium(of peer: UUID) -> Medium
    // Requirements, not just extension defaults: through the protocol type an extension-only method never reaches the transport's own version.
    func setWiFiEnabled(_ enabled: Bool)
    func isInitiator(_ peer: UUID) -> Bool
    func close(_ peer: UUID)
    func resumeAll()
    func setScanning(_ scanning: Bool)
    func setLocalName(_ name: String)
}

extension MessageTransport {
    func priority(of peer: UUID) -> Int { 1 }
    func medium(of peer: UUID) -> Medium { .bluetooth }
    /// Wi-Fi is only kept up while something needs it.
    func setWiFiEnabled(_ enabled: Bool) {}

    func send(_ message: Envelope, to peer: UUID) {
        send(message, to: peer, lane: .control)
    }

    func isInitiator(_ peer: UUID) -> Bool { false }
    func close(_ peer: UUID) {}
    func resumeAll() {}
    func setScanning(_ scanning: Bool) {}
    func setLocalName(_ name: String) {}
}

final class Hub {
    let store = DeviceStore()
    let local: RemoteDevice
    let security = SecurityContext()
    var onRemoteArtwork: ((String, Data) -> Void)?
    var onPairingRequest: (() -> Void)?

    private struct Link {
        let nonce = PairingMath.nonce()
        var hello: Hello?
        var key: SymmetricKey?
        var sentSequence: UInt64 = 0
        var highestReceived: UInt64 = 0
        var recentlyReceived: Set<UInt64> = []

        mutating func accept(_ sequence: UInt64) -> Bool {
            guard Self.isRecent(sequence, highest: highestReceived), recentlyReceived.insert(sequence).inserted else { return false }
            highestReceived = max(highestReceived, sequence)
            if recentlyReceived.count > 512 {
                recentlyReceived = recentlyReceived.filter { Self.isRecent($0, highest: highestReceived) }
            }
            return true
        }
        var sentState: PlaybackState?
        var sentArtworkID: String?

        /// Written without addition, which would overflow for a sequence near the top of the range.
        private static func isRecent(_ sequence: UInt64, highest: UInt64) -> Bool {
            highest < 256 || sequence > highest - 256
        }
    }

    private struct PairingSession {
        let id = UUID()
        let deviceID: String
        /// The key the code was compared for; the pairing trusts this and nothing a later hello says.
        let peerKey: Data
        let link: UUID
        let isInitiator: Bool
        let localNonce = PairingMath.nonce()
        var commitment: Data?
        var peerNonce: Data?
        var localConfirmed = false
        var remoteConfirmed = false
    }

    private let player: LocalPlayer
    private let transport: MessageTransport
    private var linkStates: [UUID: Link] = [:]
    private var owners: [UUID: RemoteDevice] = [:]
    private var links: [String: [UUID]] = [:]
    private var pairing: PairingSession?
    private var artworkCache: [String: Data] = [:]
    private var artworkCacheOrder: [String] = []
    private var artworkFetches: Set<String> = []
    private var artworkSongs: [String: String] = [:]
    private var previews: (id: String, data: Data)?
    private var removals: [String: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var fastPollTask: Task<Void, Never>?
    private var controllers: [String: String] = [:]
    private var localTokens: PushTokens?
    private var peerTokens: [String: PushTokens] = Hub.loadPeerTokens()
    private var lastStartPush: [String: ContinuousClock.Instant] = [:]
    private var lastPushedState: PlaybackState?
    private var controllerActivity: [String: ContinuousClock.Instant] = [:]
    private var controllerPolled: [String: ContinuousClock.Instant] = [:]
    private var mobilePolled: [String: ContinuousClock.Instant] = [:]
    private var lastPlaying: [String: ContinuousClock.Instant] = [:]
    var wantsDiscovery = true {
        didSet { updateDiscovery() }
    }
    private var localFocus: String?
    private var preparedSignatures: [String: String] = [:]
    private var pendingQueues: [String: [TrackReference]] = [:]
    private var jam: JamCoordinator!
    /// The Jam this device hosts, announced to everyone nearby in each hello.
    private var localAdvert: JamAdvert?
    /// A Jam this device asked to join as a guest, and whether it wants to play there.
    private var guestRequest: (id: UUID, host: String, playsHere: Bool)?
    /// Devices this one invited to its Jam as guests; only they can accept.
    private var invitedGuests: Set<String> = []
    /// Catalog artwork that couldn't be fetched, so it isn't asked for again at every state update.
    private var artworkMisses: [String: ContinuousClock.Instant] = [:]

    init(info: DeviceInfo, player: LocalPlayer, transport: MessageTransport, pollInterval: Duration? = nil) {
        self.player = player
        self.transport = transport
        local = RemoteDevice(info: info, isLocal: true)
        local.onCommand = { [player] in player.perform($0) }
        local.onRefresh = { [player] in player.refresh() }
        local.onFetchQueue = { [player] in await player.upcomingTracks() as [TrackReference]? }
        store.devices = [local]
        store.autoSelect(local.id)
        store.onPair = { [weak self] in self?.pair(with: $0) }
        store.onForget = { [weak self] in self?.forget($0) }
        store.onTransfer = { [weak self] in self?.transfer(from: $0, to: $1) }
        let links = JamLinks(
            send: { [weak self] message, id in self?.sendSecure(.jam(message), toDevice: id, fast: true) ?? false },
            advertise: { [weak self] in self?.advertise($0) },
            inviteGuest: { [weak self] in self?.inviteGuest($0) },
            askToJoin: { [weak self] in self?.askToJoin($0, playsHere: $1) },
            dismissGuest: { [weak self] in self?.dismissGuest($0) }
        )
        jam = JamCoordinator(local: local, player: player, store: store, links: links)
        store.onStartJam = { [jam] in jam?.start() }
        store.onLeaveJam = { [jam] in jam?.leave() }
        store.onInviteToJam = { [jam] in jam?.invite($0) }
        store.onJoinJam = { [jam] in jam?.join($0, playsHere: $1) }
        store.onSetJamPlays = { [jam] in jam?.setPlays($0, $1) }
        store.onPlayOnAll = { [jam] in jam?.playOnAll($0) }
        #if os(macOS)
        store.onTuneJam = { [jam] in await jam?.tuneByEar() ?? "" }
        #endif

        player.onChange = { [weak self] in self?.localDidChange() }
        transport.onConnect = { [weak self] in self?.linkConnected($0) }
        transport.onDisconnect = { [weak self] in self?.linkDisconnected($0) }
        transport.onMessage = { [weak self] in self?.receive($0, from: $1) }
        localDidChange()
        observeJam()
        updateDiscovery()

        if let pollInterval {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    self?.pollMobilePeers()
                }
            }
            fastPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.pollControllers()
                }
            }
        }
    }

    func rename(_ name: String) {
        local.info.name = name
        transport.setLocalName(name)
        for (link, state) in linkStates {
            transport.send(.hello(Hello(info: local.info, publicKey: security.publicKey, nonce: state.nonce, jam: localAdvert)), to: link)
        }
    }

    func setControllerFocus(_ target: String?) {
        guard localFocus != target else { return }
        localFocus = target
        for device in store.remotes {
            sendSecure(.controllerFocus(target: target), toDevice: device.id)
        }
    }

    private func pollControllers() {
        let now = ContinuousClock.now
        for (controller, target) in controllers {
            let isPlaying = target == local.id ? local.state.isPlaying : store.device(id: target)?.state.isPlaying ?? false
            guard isPlaying else { continue }
            let isActive = controllerActivity[controller].map { now - $0 < .seconds(90) } ?? false
            let interval: Duration = isActive ? .seconds(1) : .seconds(5)
            if let last = controllerPolled[controller], now - last < interval { continue }
            controllerPolled[controller] = now
            sendSecure(.requestState, toDevice: controller)
        }
    }

    private func updateDiscovery() {
        let missing = security.trusted.keys.contains { store.device(id: $0)?.isConnected != true }
        transport.setScanning(wantsDiscovery || missing)
        updateWiFi()
    }

    private var wifiOn = false
    private var wifiTarget: Bool?
    private var wifiTask: Task<Void, Never>?

    /// Wi-Fi costs far more power than Bluetooth, so it is only up for a Jam, for a device Bluetooth can't reach,
    /// or while the app is in front and a paired device hasn't shown up over Bluetooth.
    private func wifiWanted() -> (wanted: Bool, urgent: Bool) {
        let jamActive = store.jam != nil || localAdvert != nil
        let onlyWiFi = store.remotes.contains { device in
            let open = (links[device.id] ?? []).filter { linkStates[$0] != nil }
            return !open.isEmpty && open.allSatisfy { transport.medium(of: $0) == .wifi }
        }
        let missing = security.trusted.keys.contains { store.device(id: $0)?.isConnected != true }
        let urgent = jamActive || onlyWiFi
        return (urgent || (missing && wantsDiscovery), urgent)
    }

    private func updateWiFi() {
        let (wanted, urgent) = wifiWanted()
        if wanted == wifiOn {
            wifiTask?.cancel()
            wifiTask = nil
            wifiTarget = nil
            return
        }
        guard wifiTarget != wanted else { return }
        wifiTask?.cancel()
        wifiTarget = wanted
        // let Bluetooth connect first; and don't flap at the edge of its range
        let delay: Duration = wanted ? (urgent ? .zero : .seconds(8)) : .seconds(60)
        wifiTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, wifiWanted().wanted == wanted else { return }
            wifiOn = wanted
            wifiTarget = nil
            wifiTask = nil
            hubLog.info("Wi-Fi link \(wanted ? "on" : "off", privacy: .public)")
            transport.setWiFiEnabled(wanted)
        }
    }

    private func observeJam() {
        withObservationTracking {
            _ = store.jam
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateWiFi()
                self?.observeJam()
            }
        }
    }

    /// Two links over the same medium to one device are one too many; one over each is deliberate.
    private func dropDuplicateLinks(of device: RemoteDevice) {
        guard local.id > device.id else { return }
        let keyed = (links[device.id] ?? []).filter { linkStates[$0]?.key != nil }
        for medium in [Medium.bluetooth, .wifi] {
            let same = keyed.filter { transport.medium(of: $0) == medium }
            guard same.contains(where: { !transport.isInitiator($0) }) else { continue }
            for link in same where transport.isInitiator(link) {
                transport.close(link)
            }
        }
    }

    func setPushTokens(_ tokens: PushTokens) {
        guard tokens != localTokens else { return }
        localTokens = tokens
        for device in store.remotes {
            sendSecure(.pushTokens(tokens), toDevice: device.id)
        }
    }

    private static func loadPeerTokens() -> [String: PushTokens] {
        guard let data = UserDefaults.standard.data(forKey: "peerPushTokens") else { return [:] }
        return (try? JSONDecoder().decode([String: PushTokens].self, from: data)) ?? [:]
    }

    private func savePeerTokens() {
        UserDefaults.standard.set(try? JSONEncoder().encode(peerTokens), forKey: "peerPushTokens")
    }

    private func pushLiveActivities() {
        let current = player.state
        let previous = lastPushedState ?? .idle
        lastPushedState = current
        guard PushRelay.isConfigured, current.hasTrack else { return }

        let started = current.isPlaying && !previous.isPlaying
        let changed = current.isPlaying != previous.isPlaying || current.track.signature != previous.track.signature
        guard changed else { return }

        let artworkKey = current.catalogID.map { "catalog-\($0)" } ?? current.artworkID
        for (peerID, tokens) in peerTokens where security.trusted[peerID] != nil {
            let peer = store.device(id: peerID)
            if let token = tokens.activityTokens[local.id] {
                guard peer?.isConnected != true,
                      let payload = PushRelay.payload(event: "update", state: current, device: local.info, artworkID: artworkKey, tint: local.tint, alert: false)
                else { continue }
                Task { await PushRelay.send(token: token, environment: tokens.environment, payload: payload, priority: started ? 10 : 5) }
            } else if started, peer?.state.isPlaying != true, let token = tokens.startToken {
                if let last = lastStartPush[peerID], ContinuousClock.now - last < .seconds(60) { continue }
                guard let payload = PushRelay.payload(event: "start", state: current, device: local.info, artworkID: artworkKey, tint: local.tint, alert: true) else { continue }
                lastStartPush[peerID] = .now
                Task { await PushRelay.send(token: token, environment: tokens.environment, payload: payload, priority: 10) }
            }
        }
    }

    func refreshLocal() {
        player.refresh()
    }

    func transfer(from source: RemoteDevice, to target: RemoteDevice) {
        guard store.transfer == nil, source.state.hasTrack, source.isControllable, target.isControllable else { return }
        let track = source.state.track
        let (shuffle, repeatMode) = (source.state.shuffle, source.state.repeatMode)
        let status = TransferStatus(targetName: target.displayName)
        withAnimation {
            store.transfer = status
            store.autoSelect(target.id)
        }
        if !source.isLocal { source.refresh() }
        target.expectPlayback(of: track)

        Task {
            let began = ContinuousClock.now
            var fetched = await upcomingTracks(of: source)
            if fetched == nil { fetched = await upcomingTracks(of: source) }
            let upcoming = fetched ?? []
            target.send(.loadTrack(track, at: source.state.elapsed(at: .now), upcoming: upcoming))

            let loadDeadline = ContinuousClock.now + .seconds(6)
            while target.reportedState.loadedSignature != track.signature, ContinuousClock.now < loadDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }

            let loadedAt = ContinuousClock.now
            let fade: TimeInterval = source.info.kind == .mac || source.info.kind == .macBook ? 0.3 : 0
            let position = source.state.elapsed(at: .now) + fade
            source.send(.handOff)
            // the source lets go of the headphones before the target starts, or they jump back and forth
            let settleDeadline = ContinuousClock.now + .milliseconds(1200)
            while source.reportedState.isPlaying, ContinuousClock.now < settleDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            let pausedAt = ContinuousClock.now
            target.send(.startLoaded(at: position))

            let startDeadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < startDeadline {
                let reported = target.reportedState
                if reported.isPlaying, TrackMatcher.sameSong(reported.title, track.title) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let reported = target.reportedState
            let started = reported.isPlaying && TrackMatcher.sameSong(reported.title, track.title)
            hubLog.info("transfer: loaded \((loadedAt - began) / .milliseconds(1)) ms, source paused \((pausedAt - loadedAt) / .milliseconds(1)) ms later, target playing \((ContinuousClock.now - pausedAt) / .milliseconds(1)) ms later, started=\(started)")

            if started {
                if let shuffle { target.send(.setShuffle(shuffle)) }
                if let repeatMode { target.send(.setRepeat(repeatMode)) }
                source.send(.release)
                withAnimation { store.transfer = nil }
            } else {
                target.clearPlaybackExpectation()
                source.send(.play)
                withAnimation {
                    status.phase = .failed
                    store.autoSelect(source.id)
                }
                try? await Task.sleep(for: .seconds(2.5))
                if store.transfer === status {
                    withAnimation { store.transfer = nil }
                }
            }
        }
    }

    /// Nil when the device didn't answer in time, so a slow link isn't mistaken for an empty queue.
    func upcomingTracks(of device: RemoteDevice) async -> [TrackReference]? {
        if device.isLocal { return await player.upcomingTracks() }
        let link = activeLink(for: device.id)
        guard let link else { return nil }
        pendingQueues[device.id] = nil
        sendSecure(.requestQueue, to: link)
        let deadline = ContinuousClock.now + .seconds(2.5)
        while pendingQueues[device.id] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return pendingQueues.removeValue(forKey: device.id)
    }

    private func schedulePreparation(for device: RemoteDevice) {
        let state = device.reportedState
        guard state.hasTrack else { return }
        let signature = state.track.signature
        guard preparedSignatures[device.id] != signature else { return }
        preparedSignatures[device.id] = signature
        let wait = max(0, 5 - state.elapsed(at: .now))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, device.reportedState.track.signature == signature else { return }
            player.prepare(device.reportedState.track)
        }
    }

    /// Bluetooth unless `fast` asks for Wi-Fi, whose steadier timing Jam sync needs.
    private func activeLink(for id: String, fast: Bool = false) -> UUID? {
        let keyed = links[id]?.filter { linkStates[$0]?.key != nil } ?? []
        let link = (fast ? keyed.first { transport.medium(of: $0) == .wifi } : nil)
            ?? keyed.max { transport.priority(of: $0) < transport.priority(of: $1) }
        if let link { noteMedium(of: id, link) }
        return link
    }

    private var lastMedium: [String: Medium] = [:]

    private func noteMedium(of id: String, _ link: UUID) {
        let medium = transport.medium(of: link)
        guard lastMedium.updateValue(medium, forKey: id) != medium else { return }
        hubLog.info("\(id.prefix(8), privacy: .public) now over \(String(describing: medium), privacy: .public)")
    }

    private func sendSecure(_ message: Message, to link: UUID, lane: Lane = .control) {
        guard var state = linkStates[link], let key = state.key else { return }
        state.sentSequence += 1
        guard let box = SecureBox.seal(message, sequence: state.sentSequence, senderNonce: state.nonce, key: key) else { return }
        linkStates[link] = state
        transport.send(.sealed(sequence: state.sentSequence, box: box), to: link, lane: lane)
    }

    @discardableResult
    private func sendSecure(_ message: Message, toDevice id: String, fast: Bool = false) -> Bool {
        guard let link = activeLink(for: id, fast: fast) else { return false }
        sendSecure(message, to: link)
        return true
    }

    private func pollMobilePeers() {
        let now = ContinuousClock.now
        for device in store.remotes where device.isConnected && device.info.kind != .mac && device.info.kind != .macBook {
            if device.state.isPlaying { lastPlaying[device.id] = now }
            let recentlyPlayed = lastPlaying[device.id].map { now - $0 < .seconds(120) } ?? false
            let interval: Duration = recentlyPlayed ? .seconds(15) : .seconds(60)
            if let last = mobilePolled[device.id], now - last < interval - .seconds(1) { continue }
            mobilePolled[device.id] = now
            sendSecure(.requestState, toDevice: device.id)
        }
    }

    private func localDidChange() {
        let state = player.state
        if let key = state.artworkID, key != local.artworkKey, let artwork = player.artwork, artwork.id == key {
            local.setArtwork(artwork.data, key: key)
            artworkSongs[local.id] = state.track.signature
        } else if state.artworkID == nil, local.artworkKey != nil, artworkSongs[local.id] != state.track.signature {
            local.setArtwork(nil, key: nil)
            artworkSongs[local.id] = nil
        }
        update(local, to: player.state)
        jam?.localDidChange()
        for device in store.devices where !device.isLocal && device.isPaired {
            if let link = activeLink(for: device.id) { push(to: link) }
        }
        pushLiveActivities()
    }

    private func update(_ device: RemoteDevice, to state: PlaybackState) {
        let started = state.isPlaying && !device.state.isPlaying
        withAnimation(.smooth) {
            device.receive(state)
            guard state.isPlaying, device.isControllable, store.selectedID != device.id else { return }
            let selectedIsIdle = store.selected?.state.isPlaying != true
            let manualIsRecent = store.lastManualSelection.map { ContinuousClock.now - $0 < .seconds(30) } ?? false
            if started || (selectedIsIdle && !manualIsRecent) {
                store.autoSelect(device.id)
            }
        }
    }

    private func push(to link: UUID, force: Bool = false) {
        guard let state = linkStates[link], state.key != nil else { return }
        let current = player.state
        if force || state.sentState.map(current.differs(from:)) ?? true {
            sendSecure(.state(current), to: link)
            linkStates[link]?.sentState = current
        }
        if let artwork = player.artwork, artwork.id == current.artworkID, state.sentArtworkID != artwork.id, let preview = preview(for: artwork) {
            sendSecure(.artwork(id: artwork.id, data: preview), to: link, lane: .bulk)
            linkStates[link]?.sentArtworkID = artwork.id
        }
    }

    private func preview(for artwork: Artwork) -> Data? {
        if let previews, previews.id == artwork.id { return previews.data }
        guard let data = ArtworkEncoding.thumbnail(from: artwork.data, maxPixelSize: 220, quality: 0.6) else { return nil }
        previews = (artwork.id, data)
        return data
    }

    private func cacheArtwork(_ data: Data, for key: String) {
        if artworkCache[key] == nil { artworkCacheOrder.append(key) }
        artworkCache[key] = data
        while artworkCacheOrder.count > 40 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
    }

    private func refreshArtwork(for device: RemoteDevice) {
        let state = device.state
        let catalogKey = state.catalogID.map { "catalog-\($0)" }
        let candidates = [catalogKey, state.artworkID].compactMap { $0 }

        if let key = candidates.first(where: { artworkCache[$0] != nil }) {
            if device.artworkKey != key, let data = artworkCache[key] {
                device.setArtwork(data, key: key)
                artworkSongs[device.id] = state.track.signature
                onRemoteArtwork?(key, data)
            }
        } else if device.artworkKey != nil, artworkSongs[device.id] != state.track.signature {
            device.setArtwork(nil, key: nil)
            artworkSongs[device.id] = nil
        }

        guard let catalogID = state.catalogID, let catalogKey, artworkCache[catalogKey] == nil,
              artworkMisses[catalogKey].map({ ContinuousClock.now - $0 > .seconds(300) }) ?? true,
              artworkFetches.insert(catalogKey).inserted
        else { return }
        Task {
            let track = TrackReference(catalogID: catalogID, title: state.title, artist: state.artist, album: state.album, duration: state.duration)
            let result = await CatalogLookup.resolve(track, needsArtwork: true)
            artworkFetches.remove(catalogKey)
            guard let data = result.artwork else {
                artworkMisses[catalogKey] = .now
                return
            }
            artworkMisses[catalogKey] = nil
            cacheArtwork(data, for: catalogKey)
            for device in store.remotes where device.state.catalogID == catalogID {
                refreshArtwork(for: device)
            }
        }
    }

    private func linkConnected(_ link: UUID) {
        let state = Link()
        linkStates[link] = state
        transport.send(.hello(Hello(info: local.info, publicKey: security.publicKey, nonce: state.nonce, jam: localAdvert)), to: link)
    }

    private func linkDisconnected(_ link: UUID) {
        linkStates[link] = nil
        if pairing?.link == link { endPairing(.cancelled) }
        guard let device = owners.removeValue(forKey: link) else { return }
        links[device.id]?.removeAll { $0 == link }

        if let promoted = activeLink(for: device.id) {
            push(to: promoted, force: true)
            return
        }
        guard links[device.id]?.isEmpty ?? true else { return }

        links[device.id] = nil
        controllers[device.id] = nil
        jam.deviceDisconnected(device.id)
        transport.resumeAll()
        updateDiscovery()
        removals[device.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { device.isConnected = false }
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, !device.isConnected else { return }
            withAnimation { self?.store.devices.removeAll { $0 === device } }
        }
    }

    private func receive(_ envelope: Envelope, from link: UUID) {
        switch envelope {
        case .hello(let hello):
            register(hello, link: link)
        case .pairing(let message):
            handlePairing(message, from: link)
        case .guest(let message):
            handleGuest(message, from: link)
        case .sealed(let sequence, let box):
            guard let state = linkStates[link], let key = state.key, let hello = state.hello,
                  let message = SecureBox.open(box, sequence: sequence, senderNonce: hello.nonce, key: key),
                  linkStates[link]?.accept(sequence) == true
            else { return }
            handle(message, from: link)
        }
    }

    private func handle(_ message: Message, from link: UUID) {
        guard let device = owners[link] else { return }
        guard device.access == .full || Self.guestMayDo(message, as: device.access) else { return }
        switch message {
        case .state(let state):
            device.stateRevision += 1
            update(device, to: state)
            refreshArtwork(for: device)
            schedulePreparation(for: device)
        case .artwork(let id, let data):
            cacheArtwork(data, for: id)
            refreshArtwork(for: device)
        case .command(let command):
            if controllers[device.id] != nil { controllerActivity[device.id] = .now }
            player.perform(command)
        case .requestState:
            player.refresh()
            push(to: link, force: true)
        case .unpair:
            security.forget(device.id)
            peerTokens[device.id] = nil
            savePeerTokens()
            markUnpaired(device)
        case .requestQueue:
            Task {
                let upcoming = await player.upcomingTracks()
                sendSecure(.queue(upcoming), to: link)
            }
        case .queue(let upcoming):
            pendingQueues[device.id] = upcoming
        case .jam(let message):
            jam.receive(message, from: device.id)
        case .pushTokens(let tokens):
            peerTokens[device.id] = tokens
            savePeerTokens()
        case .controllerFocus(let target):
            controllers[device.id] = target
            controllerActivity[device.id] = target == nil ? nil : .now
        }
    }

    /// A guest can follow the Jam and add songs to it. It can't control the leader or be controlled.
    private static func guestMayDo(_ message: Message, as access: RemoteDevice.Access) -> Bool {
        switch message {
        case .state, .artwork, .jam, .requestState, .requestQueue, .queue:
            return true
        case .command(.enqueue), .command(.enqueueAll):
            return access == .guestMember
        default:
            return false
        }
    }

    // MARK: Jam guests

    private func advertise(_ advert: JamAdvert?) {
        localAdvert = advert
        if advert == nil { invitedGuests = [] }
        updateWiFi()
        for (link, state) in linkStates {
            transport.send(.hello(Hello(info: local.info, publicKey: security.publicKey, nonce: state.nonce, jam: advert)), to: link)
        }
    }

    private func inviteGuest(_ device: RemoteDevice) {
        guard let advert = localAdvert, let link = links[device.id]?.first else { return }
        invitedGuests.insert(device.id)
        transport.send(.guest(.invite(advert)), to: link)
    }

    private func askToJoin(_ host: RemoteDevice, playsHere: Bool) {
        guard let advert = host.jamAdvert, let link = links[host.id]?.first else { return }
        guestRequest = (advert.id, host.id, playsHere)
        transport.send(.guest(.request(advert.id)), to: link)
    }

    /// Trusts a device for the Jam only. Both sides do this, then talk like paired devices within the guest's limits.
    private func admitGuest(_ device: RemoteDevice, hello: Hello, link: UUID, as access: RemoteDevice.Access) {
        security.admitGuest(hello)
        device.access = access
        for candidate in links[device.id] ?? [] where linkStates[candidate]?.hello?.publicKey == hello.publicKey {
            establish(candidate)
        }
    }

    private func dismissGuest(_ id: String) {
        security.dismissGuest(id)
        guard let device = store.device(id: id), device.access != .full else { return }
        markUnpaired(device)
        device.access = .full
    }

    private func handleGuest(_ message: GuestMessage, from link: UUID) {
        guard let device = owners[link], let hello = linkStates[link]?.hello, !security.isTrusted(hello) else { return }
        switch message {
        case .invite(let advert):
            guard store.jam == nil else { return transport.send(.guest(.decline(advert.id)), to: link) }
            let prompt = JamPrompt(kind: .invite, deviceName: device.info.name, deviceSymbol: device.info.kind.symbol, isGuest: true)
            prompt.respond = { [weak self] accepted, plays in
                guard let self else { return }
                store.jamPrompt = nil
                guard accepted else { return transport.send(.guest(.decline(advert.id)), to: link) }
                // accept goes first: the key the other side needs comes with it, and a state sealed before it would be lost
                transport.send(.guest(.accept(advert.id)), to: link)
                jam.expectInvite(to: advert.id, playsHere: plays)
                admitGuest(device, hello: hello, link: link, as: .guestHost)
            }
            store.jamPrompt = prompt
        case .request(let id):
            guard localAdvert?.id == id else { return transport.send(.guest(.decline(id)), to: link) }
            let prompt = JamPrompt(kind: .request, deviceName: device.info.name, deviceSymbol: device.info.kind.symbol, isGuest: true)
            prompt.respond = { [weak self] accepted, _ in
                guard let self else { return }
                store.jamPrompt = nil
                guard accepted else { return transport.send(.guest(.decline(id)), to: link) }
                transport.send(.guest(.accept(id)), to: link)
                admitGuest(device, hello: hello, link: link, as: .guestMember)
                jam.invite(device)
            }
            store.jamPrompt = prompt
        case .accept(let id):
            if localAdvert?.id == id, invitedGuests.contains(device.id) {
                admitGuest(device, hello: hello, link: link, as: .guestMember)
                jam.invite(device)
            } else if let request = guestRequest, request.id == id, request.host == device.id {
                guestRequest = nil
                jam.expectInvite(to: id, playsHere: request.playsHere)
                admitGuest(device, hello: hello, link: link, as: .guestHost)
            }
        case .decline(let id):
            if localAdvert?.id == id { invitedGuests.remove(device.id) }
            if guestRequest?.id == id, guestRequest?.host == device.id { guestRequest = nil }
        }
    }

    private func register(_ hello: Hello, link: UUID) {
        let info = hello.info
        guard info.id != local.id else { return }
        // a link keeps the identity it first announced
        if let owner = owners[link], owner.id != info.id { return }
        removals.removeValue(forKey: info.id)?.cancel()
        if let previous = linkStates[link]?.hello, previous.nonce != hello.nonce, let ourNonce = linkStates[link]?.nonce {
            linkStates[link]?.key = nil
            linkStates[link]?.highestReceived = 0
            linkStates[link]?.recentlyReceived = []
            linkStates[link]?.sentState = nil
            linkStates[link]?.sentArtworkID = nil
            transport.send(.hello(Hello(info: local.info, publicKey: security.publicKey, nonce: ourNonce, jam: localAdvert)), to: link)
        }
        linkStates[link]?.hello = hello

        let device = store.device(id: info.id) ?? {
            let device = RemoteDevice(info: info, isLocal: false)
            withAnimation { store.devices.append(device) }
            return device
        }()
        let isTrusted = security.isTrusted(hello)
        let isGuest = security.isGuest(hello) && device.access != .full
        let hasKeyedLink = (links[info.id] ?? []).contains { $0 != link && linkStates[$0]?.key != nil }
        if !isTrusted, !isGuest, hasKeyedLink {
            // someone claiming a device that is already connected securely can't change what we show for it
            if owners[link] == nil {
                owners[link] = device
                links[info.id, default: []].append(link)
            }
            return
        }

        device.info = info
        device.isConnected = true
        device.onCommand = { [weak self] in self?.sendSecure(.command($0), toDevice: info.id) }
        device.onRefresh = { [weak self] in self?.sendSecure(.requestState, toDevice: info.id) }
        device.onFetchQueue = { [weak self, weak device] in
            guard let self, let device else { return nil }
            return await self.upcomingTracks(of: device)
        }

        if owners[link] == nil {
            owners[link] = device
            links[info.id, default: []].append(link)
        }

        device.jamAdvert = hello.jam
        if isTrusted {
            device.access = .full
            establish(link)
        } else if isGuest {
            establish(link)
        } else {
            device.isPaired = false
        }
    }

    private func establish(_ link: UUID) {
        guard let state = linkStates[link], let hello = state.hello, let device = owners[link] else { return }
        if state.key == nil {
            linkStates[link]?.key = security.sessionKey(with: hello, localNonce: state.nonce)
        }
        withAnimation { device.isPaired = true }
        if activeLink(for: device.id) == link {
            push(to: link, force: true)
            if device.access == .full, let localFocus {
                sendSecure(.controllerFocus(target: localFocus), to: link)
            }
            if device.access == .full, let localTokens {
                sendSecure(.pushTokens(localTokens), to: link)
            }
        }
        dropDuplicateLinks(of: device)
        updateDiscovery()
        jam.deviceConnected(device)
    }

    private func markUnpaired(_ device: RemoteDevice) {
        for link in links[device.id] ?? [] {
            linkStates[link]?.key = nil
            linkStates[link]?.sentState = nil
            linkStates[link]?.sentArtworkID = nil
        }
        withAnimation {
            device.isPaired = false
            device.state = .idle
            device.setArtwork(nil, key: nil)
        }
    }

    private func forget(_ id: String) {
        if let link = activeLink(for: id) {
            sendSecure(.unpair, to: link)
        }
        security.forget(id)
        peerTokens[id] = nil
        savePeerTokens()
        updateDiscovery()
        if let device = store.device(id: id) {
            markUnpaired(device)
        }
    }

    private func pair(with device: RemoteDevice) {
        guard pairing == nil, let link = links[device.id]?.first, let key = linkStates[link]?.hello?.publicKey else { return }
        pairing = PairingSession(deviceID: device.id, peerKey: key, link: link, isInitiator: true)
        showPrompt(for: device)
        transport.send(.pairing(.request), to: link)
    }

    private func handlePairing(_ message: PairingMessage, from link: UUID) {
        guard let peerKey = linkStates[link]?.hello?.publicKey, let device = owners[link] else { return }

        switch message {
        case .request:
            guard pairing == nil else {
                transport.send(.pairing(.confirm(false)), to: link)
                return
            }
            let session = PairingSession(deviceID: device.id, peerKey: peerKey, link: link, isInitiator: false)
            pairing = session
            showPrompt(for: device)
            onPairingRequest?()
            let commitment = PairingMath.commitment(responderKey: security.publicKey, initiatorKey: peerKey, responderNonce: session.localNonce)
            transport.send(.pairing(.commit(commitment)), to: link)

        case .commit(let commitment):
            guard var session = pairing, session.link == link, session.isInitiator, session.commitment == nil else { return }
            session.commitment = commitment
            pairing = session
            transport.send(.pairing(.nonce(session.localNonce)), to: link)

        case .nonce(let nonce):
            guard var session = pairing, session.link == link, session.peerNonce == nil else { return }
            if session.isInitiator {
                let expected = PairingMath.commitment(responderKey: peerKey, initiatorKey: security.publicKey, responderNonce: nonce)
                guard expected == session.commitment else { return endPairing(.cancelled) }
            } else {
                transport.send(.pairing(.nonce(session.localNonce)), to: link)
            }
            session.peerNonce = nonce
            pairing = session
            let (initiatorKey, responderKey) = session.isInitiator ? (security.publicKey, peerKey) : (peerKey, security.publicKey)
            let (initiatorNonce, responderNonce) = session.isInitiator ? (session.localNonce, nonce) : (nonce, session.localNonce)
            store.pairingPrompt?.code = PairingMath.code(initiatorKey: initiatorKey, responderKey: responderKey, initiatorNonce: initiatorNonce, responderNonce: responderNonce)
            store.pairingPrompt?.phase = .comparing

        case .confirm(let accepted):
            guard var session = pairing, session.link == link else { return }
            guard accepted else { return endPairing(.cancelled) }
            session.remoteConfirmed = true
            pairing = session
            completePairingIfReady()
        }
    }

    private func respondToPairing(_ accepted: Bool) {
        guard var session = pairing else { return }
        guard accepted, session.peerNonce != nil else {
            transport.send(.pairing(.confirm(false)), to: session.link)
            return endPairing(.cancelled)
        }
        session.localConfirmed = true
        pairing = session
        store.pairingPrompt?.phase = .waitingForPeer
        transport.send(.pairing(.confirm(true)), to: session.link)
        completePairingIfReady()
    }

    private func completePairingIfReady() {
        guard let session = pairing, session.localConfirmed, session.remoteConfirmed,
              let hello = linkStates[session.link]?.hello
        else { return }
        // the device whose code was compared, not whatever the link says now
        guard hello.publicKey == session.peerKey, hello.info.id == session.deviceID else { return endPairing(.cancelled) }
        security.trust(hello)
        endPairing(.paired)
        for link in links[hello.info.id] ?? [] where linkStates[link]?.hello?.publicKey == hello.publicKey {
            establish(link)
        }
        store.autoSelect(hello.info.id)
    }

    private func showPrompt(for device: RemoteDevice) {
        let prompt = PairingPrompt(deviceName: device.info.name, deviceSymbol: device.info.kind.symbol)
        prompt.respond = { [weak self] in self?.respondToPairing($0) }
        store.pairingPrompt = prompt

        let sessionID = pairing?.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, pairing?.id == sessionID else { return }
            if let link = pairing?.link {
                transport.send(.pairing(.confirm(false)), to: link)
            }
            endPairing(.cancelled)
        }
    }

    private func endPairing(_ phase: PairingPrompt.Phase) {
        pairing = nil
        guard let prompt = store.pairingPrompt else { return }
        withAnimation { prompt.phase = phase }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(phase == .paired ? 1.2 : 2))
            if self?.store.pairingPrompt === prompt {
                self?.store.pairingPrompt = nil
            }
        }
    }
}
