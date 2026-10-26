//
//  MusicAppSource.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppKit
import OSLog

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "MusicApp")

final class MusicAppSource: LocalPlayer {
    var onChange: (() -> Void)?
    private(set) var state = PlaybackState.idle
    private(set) var artwork: Artwork?

    private let audio = SystemAudio()
    private let nowPlaying = NowPlayingStream()
    private let script = MusicScript()
    private var info: NowPlayingStream.Info?
    private var trackKey: String?
    private var resolvedKeys: Set<String> = []
    private var lastRawArtwork: (data: Data, album: String?)?
    private var catalogIDs: [String: String] = [:]
    private var fallbackTask: Task<Void, Never>?
    private var streamArtwork: [String: Data] = [:]
    private var lastTrack: (info: NowPlayingStream.Info, seen: ContinuousClock.Instant)?
    private var holdTask: Task<Void, Never>?
    private var otherAppIsNowPlaying = false

    /// Every update from the system's now-playing stream, whichever app it is about.
    var onStreamUpdate: ((NowPlayingStream.Info) -> Void)?

    /// While another player is the one in use, Music only listens to the stream and runs no scripts of its own.
    var isPassive = false {
        didSet {
            guard oldValue != isPassive, !isPassive else { return }
            Task { [weak self] in
                await self?.pollMusic()
                await self?.refreshSettings()
            }
        }
    }

    init() {
        audio.onChange = { [weak self] in self?.publish() }
        nowPlaying.onUpdate = { [weak self] info in
            self?.receive(info)
        }
        nowPlaying.start()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "nativeSelfTest") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                await self?.runNativeSelfTest()
            }
        }
        #endif
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard self?.isPassive == false else { continue }
                await self?.pollMusicIfNeeded()
                await self?.refreshPlaylistQueue()
                await self?.refreshSettings()
            }
        }
        advanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard self?.isPassive == false else { continue }
                self?.advanceIfFinished()
            }
        }
        Task { [weak self] in
            await CatalogLookup.requestAuthorization()
            self?.publish()
        }
        publish()
    }

    func refresh() {
        publish()
    }

    func perform(_ command: Command) {
        switch command {
        case .play: script.send("play")
        case .pause: script.send("pause")
        case .togglePlayPause: script.send("playpause")
        case .next:
            if queue.isEmpty { script.send("next track") } else { advance() }
        case .previous: script.send("back track")
        case .seek(let position): script.send("set player position to \(position)")
        case .setVolume(let volume): audio.volume = volume
        case .loadTrack(let track, let position, let upcoming):
            log.info("loadTrack \(track.title ?? "?", privacy: .public) catalogID=\(track.catalogID ?? "nil", privacy: .public) upcoming=\(upcoming.count)")
            if position < 1, isUsable(.edit), let id = queuedItemID(of: track, followedBy: upcoming) {
                loading?.cancel()
                loaded = nil
                pendingUpcoming = []
                serialized { [self] in
                    let worked = await attemptNative(.edit, send: {
                        script.editQueue([.play(id)])
                        script.send("play")
                    }, confirm: { TrackMatcher.sameSong(state.title, track.title) })
                    guard !worked else { return }
                    queue = upcoming
                    stopAfterCurrent = false
                    advancedFrom = nil
                    load(track)
                    startLoaded(at: 0)
                    publish()
                }
                break
            }
            queue = []
            pendingUpcoming = upcoming
            stopAfterCurrent = false
            advancedFrom = nil
            load(track)
        case .enqueue(let track, let next): enqueue([track], next: next)
        case .enqueueAll(let tracks, let next): enqueue(tracks, next: next)
        case .setQueue(let tracks):
            if queue.isEmpty, !stopAfterCurrent, !tracks.isEmpty, isUsable(.edit) {
                serialized { [self] in
                    if let operations = nativeQueueEdit(to: tracks) {
                        if operations.isEmpty { return }
                        if await attemptNative(.edit, send: { script.editQueue(operations) }, confirm: { upcoming(matches: tracks) }) { return }
                    }
                    queue = tracks
                    stopAfterCurrent = false
                    publish()
                }
            } else {
                queue = tracks
                stopAfterCurrent = tracks.isEmpty
            }
        case .setShuffle(let on): setSetting("set shuffle enabled to \(on)")
        case .setRepeat(let mode): setSetting("set song repeat to \(mode.rawValue)")
        case .setLiked(let liked): setSetting("set favorited of current track to \(liked)")
        case .setAirPlay(let names):
            let devices = names.map { "AirPlay device \(Self.quoted($0))" }.joined(separator: ", ")
            if !names.isEmpty { setSetting("set current AirPlay devices to {\(devices)}") }
        case .startLoaded(let position): startLoaded(at: position)
        case .handOff: fadeOutAndPause()
        case .release:
            queue = []
            stopAfterCurrent = false
        }
        publish()
    }

    private func receive(_ info: NowPlayingStream.Info) {
        var info = info
        if let encoded = info.artwork, let raw = Data(base64Encoded: encoded), let thumbnail = ArtworkEncoding.thumbnail(from: raw) {
            let signature = TrackReference(catalogID: nil, title: info.title, artist: info.artist.flatMap { $0.isEmpty ? nil : $0 }, album: info.album.flatMap { $0.isEmpty ? nil : $0 }, duration: 0).signature
            if streamArtwork.count > 8 { streamArtwork.removeAll() }
            streamArtwork[signature] = thumbnail
        }
        info.artwork = nil
        onStreamUpdate?(info)

        guard info.client == "com.apple.Music" || info.client.isEmpty else {
            otherAppIsNowPlaying = true
            // Music's own state is stale now, unless it's the one not in use
            if !isPassive { Task { await pollMusic() } }
            return
        }
        otherAppIsNowPlaying = false

        if info.client == "com.apple.Music", info.title != nil {
            lastTrack = (info, .now)
            self.info = info
        } else if let lastTrack, ContinuousClock.now - lastTrack.seen < .seconds(2) {
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.info?.title == nil || self.lastTrack?.info == self.info else { return }
                self.info = info
                self.publish()
            }
            return
        } else {
            self.info = info
        }
        holdTask?.cancel()
        publish()
    }

    private func publish() {
        var next = PlaybackState()
        next.volume = audio.volume
        next.output = audio.output

        if let info, info.client == "com.apple.Music", let title = info.title {
            next.title = title
            next.artist = info.artist.flatMap { $0.isEmpty ? nil : $0 }
            next.album = info.album.flatMap { $0.isEmpty ? nil : $0 }
            next.duration = info.duration ?? 0
            let rate = info.rate ?? 0
            let reportedAt = info.timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now
            let position = (info.elapsed ?? 0) + (rate > 0 ? Date.now.timeIntervalSince(reportedAt) * rate : 0)
            next.elapsed = next.duration > 0 ? min(next.duration, position) : position
            next.timestamp = .now
            next.isPlaying = rate > 0

            let catalogID = info.catalogID.flatMap { $0 > 0 ? String($0) : nil }
            let key = next.track.signature
            trackKey = key
            next.catalogID = catalogID ?? catalogIDs[key]
            if artwork?.id != key, let data = streamArtwork[key] {
                artwork = Artwork(id: key, data: data)
            }
            resolve(key: key, track: next.track)
            next.artworkID = artwork?.id == key ? key : nil
        } else {
            trackKey = nil
        }

        next.loadedSignature = loaded?.track.signature
        next.shuffle = settings.shuffle
        next.repeatMode = settings.repeatMode
        next.isLiked = next.hasTrack ? settings.isLiked : nil
        next.airPlay = settings.airPlay
        state = next
        onChange?()
    }

    private func pollMusicIfNeeded() async {
        if !otherAppIsNowPlaying, let lastUpdate = nowPlaying.lastUpdate, ContinuousClock.now - lastUpdate < .seconds(15) { return }
        await pollMusic()
    }

    private func pollMusic() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else { return }
        let source = """
            tell application "Music"
                set s to player state as text
                if s is "stopped" then return {s}
                set t to current track
                return {s, name of t, artist of t, album of t, duration of t, player position}
            end tell
            """
        let polled = await script.run(source) { result -> NowPlayingStream.Info? in
            guard result.numberOfItems >= 6, let status = result.atIndex(1)?.stringValue else {
                return NowPlayingStream.Info(client: "com.apple.Music")
            }
            return NowPlayingStream.Info(
                client: "com.apple.Music",
                title: result.atIndex(2)?.stringValue,
                artist: result.atIndex(3)?.stringValue,
                album: result.atIndex(4)?.stringValue,
                duration: result.atIndex(5)?.doubleValue,
                elapsed: result.atIndex(6)?.doubleValue,
                rate: status == "playing" ? 1 : 0,
                timestamp: Date.now.timeIntervalSince1970
            )
        }
        guard let polled else { return }
        info = polled
        publish()
    }

    private func resolve(key: String, track: TrackReference) {
        guard resolvedKeys.insert(key).inserted else { return }
        Task {
            for _ in 0..<6 where artwork?.id != key {
                try? await Task.sleep(for: .milliseconds(250))
                if let data = streamArtwork[key] { artwork = Artwork(id: key, data: data) }
            }
            // a track skipped past before it was resolved is looked at again if it comes back
            guard trackKey == key else {
                resolvedKeys.remove(key)
                return
            }
            if artwork?.id == key {
                publish()
                if track.catalogID != nil { return }
            }
            for attempt in 0..<6 where artwork?.id != key {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                guard trackKey == key else {
                    resolvedKeys.remove(key)
                    return
                }
                guard let raw = await currentArtworkData() else { break }
                if let last = lastRawArtwork, last.data == raw, last.album != track.album { continue }
                if let thumbnail = ArtworkEncoding.thumbnail(from: raw) {
                    lastRawArtwork = (raw, track.album)
                    artwork = Artwork(id: key, data: thumbnail)
                    publish()
                }
                break
            }

            let needsArtwork = artwork?.id != key
            guard needsArtwork || track.catalogID == nil else { return }
            let result = await CatalogLookup.resolve(track, needsArtwork: needsArtwork)
            if let id = result.catalogID { catalogIDs[key] = id }
            if let data = result.artwork, artwork?.id != key { artwork = Artwork(id: key, data: data) }
            publish()
            if result.catalogID == nil, result.artwork == nil {
                // offline or not found: try this track again later
                try? await Task.sleep(for: .seconds(30))
                resolvedKeys.remove(key)
            }
        }
    }

    private func currentArtworkData() async -> Data? {
        await script.run("tell application \"Music\" to get data of artwork 1 of current track") { $0.data.isEmpty ? nil : $0.data }
    }

    private enum Located {
        case library(Int)
        case catalog(String)
    }

    private nonisolated struct Candidate: Sendable {
        let id: Int
        let title: String
        let artist: String
        let album: String?
        let duration: Double?
    }

    private var prepared: [String: Located] = [:]
    private var preparing: Set<String> = []
    private var loading: Task<Void, Never>?
    private var loaded: (track: TrackReference, located: Located)?
    func upcomingTracks() async -> [TrackReference] {
        queue.isEmpty && !stopAfterCurrent ? systemQueue : queue
    }

    /// What Music plays after the current track. Falls back to the playlist, which has no ids, so native edits stay off.
    private var systemUpcoming: (anchor: String?, slots: [QueueSlot]) {
        guard !isForcedToFail(.read), let info, let items = info.queue, !items.isEmpty else {
            return (nil, playlistQueue.map { QueueSlot(id: nil, track: $0) })
        }
        let current = items.firstIndex { $0.id != nil && $0.id == info.itemID }
            ?? items.firstIndex { TrackMatcher.sameSong($0.title, info.title) }
            ?? 0
        let slots = items.dropFirst(current + 1).map { item in
            QueueSlot(id: item.id, track: TrackReference(
                catalogID: item.catalogID.flatMap { $0 > 0 ? String($0) : nil },
                title: item.title,
                artist: item.artist.flatMap { $0.isEmpty ? nil : $0 },
                album: item.album.flatMap { $0.isEmpty ? nil : $0 },
                duration: item.duration ?? 0
            ))
        }
        return (items[current].id, slots)
    }

    private var systemQueue: [TrackReference] { systemUpcoming.slots.map(\.track) }

    private struct Settings: Equatable {
        var shuffle: Bool?
        var repeatMode: RepeatMode?
        var isLiked: Bool?
        var airPlay: [AirPlayDevice]?
    }

    private var settings = Settings()

    private func setSetting(_ command: String) {
        script.send(command)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.refreshSettings()
        }
    }

    /// Music can list one device twice, as an AirPlay target and as a Bluetooth one. Keep the selected or the AirPlay entry.
    private nonisolated static func unique(_ devices: [AirPlayDevice]) -> [AirPlayDevice] {
        func rank(_ device: AirPlayDevice) -> Int { device.isSelected ? 3 : device.kind == .bluetooth ? 1 : 2 }
        var best: [String: AirPlayDevice] = [:]
        var order: [String] = []
        for device in devices {
            if let existing = best[device.name] {
                if rank(device) > rank(existing) { best[device.name] = device }
            } else {
                best[device.name] = device
                order.append(device.name)
            }
        }
        return order.compactMap { best[$0] }
    }

    private func refreshSettings() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else { return }
        let source = """
            tell application "Music"
                set liked to false
                try
                    set liked to favorited of current track
                end try
                set devices to {}
                repeat with d in AirPlay devices
                    if available of d then set end of devices to {name of d, (kind of d) as text, selected of d}
                end repeat
                return {shuffle enabled, (song repeat) as text, liked, devices}
            end tell
            """
        let found = await script.run(source) { result -> Settings? in
            guard result.numberOfItems >= 4 else { return nil }
            let devices = result.atIndex(4).map { list in
                Self.unique((list.numberOfItems > 0 ? Array(1...list.numberOfItems) : []).compactMap { index -> AirPlayDevice? in
                    guard let entry = list.atIndex(index), entry.numberOfItems >= 3, let name = entry.atIndex(1)?.stringValue else { return nil }
                    return AirPlayDevice(name: name, kindName: entry.atIndex(2)?.stringValue ?? "", isSelected: entry.atIndex(3)?.booleanValue ?? false)
                })
            }
            return Settings(
                shuffle: result.atIndex(1)?.booleanValue,
                repeatMode: result.atIndex(2)?.stringValue.flatMap(RepeatMode.init(rawValue:)),
                isLiked: result.atIndex(3)?.booleanValue,
                airPlay: devices
            )
        }
        guard let found, found != settings else { return }
        settings = found
        publish()
    }

    private var playlistQueue: [TrackReference] = []
    private var playlistRetryAfter = ContinuousClock.now

    private enum NativeFeature: Hashable {
        case edit, insert, start, read
    }

    // Private MediaRemote calls can break with a macOS update: two failures in a row and the fallback is used for ten minutes.
    private var health = NativeHealth<NativeFeature>()
    private var lastNativeResult: [NativeFeature: Bool] = [:]
    private var editTask: Task<Void, Never>?

    private func isUsable(_ feature: NativeFeature) -> Bool {
        health.isUsable(feature)
    }

    /// Debug only: launch with `-failNative '("edit","insert")'` to force a fallback.
    private func isForcedToFail(_ feature: NativeFeature) -> Bool {
        #if DEBUG
        UserDefaults.standard.stringArray(forKey: "failNative")?.contains("\(feature)") == true
        #else
        false
        #endif
    }

    private func attemptNative(_ feature: NativeFeature, timeout: Duration = .seconds(4), send: () -> Void, confirm: () -> Bool) async -> Bool {
        guard isUsable(feature) else { return false }
        let started = ContinuousClock.now
        if !isForcedToFail(feature) {
            send()
            while ContinuousClock.now - started < timeout {
                try? await Task.sleep(for: .milliseconds(200))
                if confirm() {
                    health.succeeded(feature)
                    lastNativeResult[feature] = true
                    log.info("native \(String(describing: feature), privacy: .public) confirmed after \((ContinuousClock.now - started) / .milliseconds(1)) ms")
                    return true
                }
            }
        }
        let count = health.failed(feature)
        lastNativeResult[feature] = false
        log.error("native \(String(describing: feature), privacy: .public) not confirmed (\(count) in a row), using the fallback")
        return false
    }

    /// One native change at a time, so each is planned against the queue the last one left.
    private func serialized(_ work: @escaping () async -> Void) {
        let previous = editTask
        editTask = Task {
            await previous?.value
            await work()
        }
    }

    private func upcoming(matches tracks: [TrackReference]) -> Bool {
        QueuePlanner.matches(systemUpcoming.slots, tracks)
    }

    private func refreshPlaylistQueue() async {
        let hasNative = info?.queue?.isEmpty == false
        guard !hasNative, info?.client == "com.apple.Music", info?.title != nil else {
            playlistQueue = []
            return
        }
        guard ContinuousClock.now >= playlistRetryAfter else { return }
        let source = """
            tell application "Music"
                if player state is stopped then return {}
                set p to current playlist
                set i to index of current track
                set n to count of tracks of p
                if i >= n then return {}
                set j to i + 25
                if j > n then set j to n
                set out to {}
                repeat with t in (tracks (i + 1) thru j of p)
                    set end of out to {name of t, artist of t, album of t, duration of t}
                end repeat
                return out
            end tell
            """
        let found = await script.run(source) { list -> [TrackReference]? in
            guard list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { index in
                guard let entry = list.atIndex(index), entry.numberOfItems >= 4 else { return nil }
                return TrackReference(
                    catalogID: nil,
                    title: entry.atIndex(1)?.stringValue,
                    artist: entry.atIndex(2)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    album: entry.atIndex(3)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    duration: entry.atIndex(4)?.doubleValue ?? 0
                )
            }
        }
        playlistQueue = found ?? []
        // a queue built from catalog songs has no playlist behind it
        if found == nil { playlistRetryAfter = .now + .seconds(30) }
    }

    /// The queue id of `track` when `upcoming` is what follows it, so Music can jump straight to it.
    private func queuedItemID(of track: TrackReference, followedBy upcoming: [TrackReference]) -> String? {
        guard queue.isEmpty, !stopAfterCurrent else { return nil }
        let slots = systemUpcoming.slots
        guard let index = slots.firstIndex(where: { $0.track.signature == track.signature }), let id = slots[index].id,
              slots.dropFirst(index + 1).map({ $0.track.signature }) == upcoming.map(\.signature) else { return nil }
        return id
    }

    private func nativeQueueEdit(to tracks: [TrackReference]) -> [MusicScript.QueueOperation]? {
        let upcoming = systemUpcoming
        return QueuePlanner.plan(target: tracks, upcoming: upcoming.slots, anchor: upcoming.anchor)?.map { edit in
            switch edit {
            case .remove(let id): .remove(id)
            case .move(let id, let after): .move(id, after: after)
            }
        }
    }

    /// Set when the user empties the queue while Music still has its own items lined up.
    private var stopAfterCurrent = false

    // Music can't queue arbitrary catalog songs from AppleScript, so Tournesol keeps its own up-next list
    // and starts the following track itself when the current one ends.
    private var queue: [TrackReference] = []
    private var advancedFrom: String?
    private var advanceTask: Task<Void, Never>?

    private func enqueue(_ tracks: [TrackReference], next: Bool) {
        guard !tracks.isEmpty else { return }
        guard queue.isEmpty, !stopAfterCurrent, isUsable(.insert), systemUpcoming.anchor != nil else { return emulateEnqueue(tracks, next: next) }
        serialized { [self] in
            if await enqueueNatively(tracks, next: next) { return }
            emulateEnqueue(tracks, next: next)
            publish()
        }
    }

    /// Tries Music's own Up Next. False means the caller should use Tournesol's list.
    private func enqueueNatively(_ tracks: [TrackReference], next: Bool) async -> Bool {
        var ids: [String] = []
        for track in tracks {
            if let id = track.catalogID, !id.isEmpty, id.allSatisfy(\.isNumber) {
                ids.append(id)
            } else if let id = await CatalogLookup.resolve(track, needsArtwork: false).catalogID, id.allSatisfy(\.isNumber) {
                ids.append(id)
            } else {
                return false
            }
        }
        // behind what we queued before, ahead of the rest of Music's queue
        let waiting = QueuePlanner.waiting(pendingAdds, in: systemUpcoming.slots)
        pendingAdds = waiting.songs
        let anchor = next ? nil : waiting.anchor
        let position = next ? 0 : waiting.songs.count
        let worked = await attemptNative(.insert, send: { script.insertIntoQueue(storeIDs: ids, next: next, after: anchor) }, confirm: {
            QueuePlanner.holds(tracks[0], at: position, in: systemUpcoming.slots)
        })
        if worked {
            if next { pendingAdds.insert(contentsOf: tracks, at: 0) } else { pendingAdds.append(contentsOf: tracks) }
        }
        return worked
    }

    /// Songs we queued that haven't played yet.
    private var pendingAdds: [TrackReference] = []

    /// The queue that came with a handed-over song, added once the song is playing.
    private var pendingUpcoming: [TrackReference] = []

    private func queueHandedOver() {
        let upcoming = pendingUpcoming
        pendingUpcoming = []
        if !upcoming.isEmpty { enqueue(upcoming, next: true) }
    }

    private func emulateEnqueue(_ tracks: [TrackReference], next: Bool) {
        let isIdle = !state.isPlaying && !state.hasTrack && loaded == nil && loading == nil
        if queue.isEmpty, !stopAfterCurrent { queue = systemQueue }
        stopAfterCurrent = false
        if next { queue.insert(contentsOf: tracks, at: 0) } else { queue.append(contentsOf: tracks) }
        log.info("enqueue \(tracks.count) next=\(next) queue=\(self.queue.count)")
        if isIdle { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        let upcoming = queue.removeFirst()
        advancedFrom = state.track.signature
        log.info("advance to \(upcoming.title ?? "?", privacy: .public)")
        load(upcoming)
        startLoaded(at: 0)
    }

    private func advanceIfFinished() {
        guard loading == nil, loaded == nil, state.title != nil, state.duration > 0, !queue.isEmpty || stopAfterCurrent else { return }
        let signature = state.track.signature
        if let advancedFrom, advancedFrom != signature { self.advancedFrom = nil }
        guard advancedFrom != signature else { return }

        let remaining = state.duration - state.elapsed(at: .now)
        if remaining < 10, let first = queue.first { prepare(first) }
        guard state.isPlaying ? remaining < 0.6 : (remaining < 1.5 && state.elapsed > 5) else { return }
        if stopAfterCurrent {
            stopAfterCurrent = false
            advancedFrom = signature
            script.send("pause")
        } else {
            advance()
        }
    }

    func prepare(_ track: TrackReference) {
        let signature = track.signature
        guard prepared[signature] == nil, preparing.insert(signature).inserted else { return }
        Task {
            if let located = await locate(track) {
                prepared[signature] = located
            }
            preparing.remove(signature)
        }
    }

    private func locate(_ track: TrackReference) async -> Located? {
        if let id = await libraryTrackID(matching: track) {
            return .library(id)
        }
        if let id = track.catalogID {
            return .catalog(id)
        }
        return await CatalogLookup.resolve(track, needsArtwork: false, allowLooseMatch: true).catalogID.map(Located.catalog)
    }

    private func libraryTrackID(matching track: TrackReference) async -> Int? {
        guard let title = track.title else { return nil }
        let source = """
            tell application "Music"
                set found to search library playlist 1 for \(Self.quoted(title)) only songs
                set output to {}
                repeat with t in found
                    set end of output to {id of t, name of t, artist of t, album of t, duration of t}
                end repeat
                return output
            end tell
            """
        let candidates = await script.run(source) { list -> [Candidate]? in
            guard list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { index in
                guard let entry = list.atIndex(index), entry.numberOfItems >= 5, let id = entry.atIndex(1)?.int32Value else { return nil }
                return Candidate(
                    id: Int(id),
                    title: entry.atIndex(2)?.stringValue ?? "",
                    artist: entry.atIndex(3)?.stringValue ?? "",
                    album: entry.atIndex(4)?.stringValue,
                    duration: entry.atIndex(5)?.doubleValue
                )
            }
        } ?? []

        let scored = candidates.map { ($0.id, TrackMatcher.score(title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration, against: track)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= TrackMatcher.loose else { return nil }
        return best.0
    }

    private func load(_ track: TrackReference) {
        loaded = nil
        loading?.cancel()
        loading = Task {
            var located = prepared[track.signature]
            if located == nil { located = await locate(track) }
            guard let located, !Task.isCancelled else {
                log.error("could not locate \(track.title ?? "?", privacy: .public)")
                return
            }
            loaded = (track, located)
            publish()
        }
    }

    /// Catalog id for a native start; songs without one go through AppleScript.
    private func nativeStartID(_ track: TrackReference, _ located: Located) -> String? {
        let id: String?
        if let known = track.catalogID, !known.isEmpty { id = known } else if case .catalog(let found) = located { id = found } else { id = nil }
        return id.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    private func startLoaded(at position: TimeInterval) {
        let received = ContinuousClock.now
        let target = { position + (ContinuousClock.now - received) / .seconds(1) }
        Task {
            await loading?.value
            loading = nil
            guard let (track, located) = loaded, let title = track.title else {
                log.error("startLoaded: nothing loaded")
                return
            }
            loaded = nil
            defer { queueHandedOver() }

            let volume = await musicVolume()
            script.send("set sound volume to 0")
            if let id = nativeStartID(track, located), await attemptNative(.start, send: { script.startPlayback(storeIDs: [id]) }, confirm: { TrackMatcher.sameSong(state.title, title) }) {
                await confirmStart(title: title, seeked: false, volume: volume, target: target)
                return
            }
            switch located {
            case .library(let id):
                script.send("play (track id \(id) of library playlist 1)")
                await confirmStart(title: title, seeked: false, volume: volume, target: target)
            case .catalog(let id):
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
                    log.error("startLoaded: \(id, privacy: .public) is not a catalog id")
                    script.send("set sound volume to \(volume)")
                    return
                }
                let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
                script.send("open location \"music://music.apple.com/\(storefront)/song/\(id)\"")
                script.send("pause")
                await confirmStart(title: title, seeked: false, volume: volume, target: target)
            }
        }
    }

    private func confirmStart(title: String, seeked: Bool, volume: Int, target: () -> TimeInterval) async {
        var seeked = seeked
        var pressedPlay = false
        var faded = false
        var playingSince: ContinuousClock.Instant?
        defer { if !faded { script.send("set sound volume to \(volume)") } }

        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            publish()
            guard TrackMatcher.sameSong(state.title, title) else { continue }
            if !seeked {
                guard !state.isPlaying else {
                    script.send("pause")
                    continue
                }
                script.send("set player position to \(target())")
                seeked = true
                script.send("play")
                continue
            }
            if !state.isPlaying {
                if !pressedPlay {
                    script.send("play")
                    pressedPlay = true
                }
                continue
            }
            if !faded {
                await fade(to: volume, from: 0)
                faded = true
            }
            let since = playingSince ?? .now
            playingSince = since
            guard ContinuousClock.now - since > .seconds(1) else { continue }
            if abs(state.elapsed(at: .now) - target()) > 2 {
                script.send("set player position to \(target())")
            }
            return
        }
    }

    private func fadeOutAndPause() {
        Task {
            let volume = await musicVolume()
            await fade(to: 0, from: volume)
            script.send("pause")
            script.send("set sound volume to \(volume)")
        }
    }

    private func fade(to end: Int, from start: Int) async {
        for step in 1...5 {
            script.send("set sound volume to \(start + (end - start) * step / 5)")
            try? await Task.sleep(for: .milliseconds(55))
        }
    }

    private func musicVolume() async -> Int {
        let volume = await script.run("tell application \"Music\" to get sound volume") { Int($0.int32Value) } ?? 100
        return volume > 0 ? volume : 100
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

#if DEBUG
extension MusicAppSource {
    /// Runs each native queue feature once and logs `SELFTEST` lines. Launch with `-nativeSelfTest YES`.
    /// It changes Music's queue and starts a song (muted), so use a scratch session.
    func runNativeSelfTest() async {
        let first = TrackReference(catalogID: "1202853498", title: "Take the Crown", artist: nil, album: nil, duration: 0)
        let second = TrackReference(catalogID: "1827235586", title: "Golden Brown (Slowed Down Version)", artist: nil, album: nil, duration: 0)
        func report(_ step: String, _ outcome: String) { log.info("SELFTEST \(step, privacy: .public): \(outcome, privacy: .public)") }
        func settle() async { try? await Task.sleep(for: .seconds(6)) }

        for _ in 0..<20 where systemUpcoming.slots.isEmpty && systemUpcoming.anchor == nil && !isForcedToFail(.read) { try? await Task.sleep(for: .milliseconds(500)) }
        let nativeRead = systemUpcoming.anchor != nil
        report("read", nativeRead ? "native" : "fallback (\(playlistQueue.count) from playlist)")
        let volume = await musicVolume()
        script.send("set sound volume to 0")

        func outcome(_ feature: NativeFeature, held: Bool) -> String {
            if held, lastNativeResult[feature] == true { return "native" }
            if lastNativeResult[feature] == false || isForcedToFail(.read) || !isUsable(feature) { return "fallback" }
            return held && !queue.isEmpty ? "own list (native not attempted)" : "FAILED"
        }

        perform(.enqueue(first, next: true))
        await settle()
        report("play next", outcome(.insert, held: QueuePlanner.holds(first, at: 0, in: systemUpcoming.slots)))

        perform(.enqueue(second, next: false))
        await settle()
        report("add to queue", outcome(.insert, held: QueuePlanner.holds(second, at: 1, in: systemUpcoming.slots)))

        var order = await upcomingTracks()
        if order.count >= 2 {
            let moved = order.removeLast()
            order.insert(moved, at: 0)
            perform(.setQueue(order))
            await settle()
            let now = await upcomingTracks()
            report("reorder", outcome(.edit, held: now.first.map { TrackMatcher.sameSong($0.title, moved.title) } == true))
            order.removeFirst()
            perform(.setQueue(order))
            await settle()
            let after = await upcomingTracks()
            report("remove", outcome(.edit, held: after.first.map { !TrackMatcher.sameSong($0.title, moved.title) } ?? true))
        } else {
            report("reorder", "skipped: the queue is too short")
        }

        let sections = await BrowseLoader.sections()
        report("browse", sections.isEmpty ? "nothing loaded (not authorized?)" : sections.map { "\($0.title) \($0.items.count)" }.joined(separator: ", "))
        report("outputs", state.airPlay.map { $0.map { "\($0.name)\($0.isSelected ? "*" : "")" }.joined(separator: ", ") } ?? "none reported")

        perform(.setShuffle(true))
        try? await Task.sleep(for: .seconds(5))
        report("shuffle", state.shuffle == true ? "ok" : "FAILED")
        perform(.setShuffle(false))
        perform(.setRepeat(.all))
        try? await Task.sleep(for: .seconds(5))
        report("repeat", state.repeatMode == .all ? "ok" : "FAILED")
        perform(.setRepeat(.off))
        try? await Task.sleep(for: .seconds(3))

        perform(.loadTrack(second, at: 0, upcoming: [first]))
        perform(.startLoaded(at: 0))
        for _ in 0..<30 where !TrackMatcher.sameSong(state.title, second.title) { try? await Task.sleep(for: .milliseconds(500)) }
        report("start", TrackMatcher.sameSong(state.title, second.title) ? outcome(.start, held: true) : "FAILED")
        await settle()
        report("handoff queue", outcome(.insert, held: QueuePlanner.holds(first, at: 0, in: systemUpcoming.slots)))

        try? await Task.sleep(for: .seconds(5))
        script.send("pause")
        script.send("set sound volume to \(volume)")
        perform(.release)
        report("done", "Music paused, volume restored")
    }
}
#endif
