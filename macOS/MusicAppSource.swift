//
//  MusicAppSource.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppKit

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

    init() {
        audio.onChange = { [weak self] in self?.publish() }
        nowPlaying.onUpdate = { [weak self] info in
            self?.receive(info)
        }
        nowPlaying.start()
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.pollMusicIfNeeded()
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
        case .next: script.send("next track")
        case .previous: script.send("back track")
        case .seek(let position): script.send("set player position to \(position)")
        case .setVolume(let volume): audio.volume = volume
        case .loadTrack(let track, _): load(track)
        case .startLoaded(let position): startLoaded(at: position)
        case .handOff: fadeOutAndPause()
        case .release: break
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

        guard info.client == "com.apple.Music" || info.client.isEmpty else {
            otherAppIsNowPlaying = true
            Task { await pollMusic() }
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
            next.elapsed = min(next.duration, (info.elapsed ?? 0) + (rate > 0 ? Date.now.timeIntervalSince(reportedAt) * rate : 0))
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
            guard trackKey == key else { return }
            if artwork?.id == key {
                publish()
                if track.catalogID != nil { return }
            }
            for attempt in 0..<6 where artwork?.id != key {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                guard trackKey == key else { return }
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
            guard let located, !Task.isCancelled else { return }
            loaded = (track, located)
            publish()
        }
    }

    private func startLoaded(at position: TimeInterval) {
        let received = ContinuousClock.now
        let target = { position + (ContinuousClock.now - received) / .seconds(1) }
        Task {
            await loading?.value
            loading = nil
            guard let (track, located) = loaded, let title = track.title else { return }
            loaded = nil

            let volume = await musicVolume()
            script.send("set sound volume to 0")
            switch located {
            case .library(let id):
                script.send("play (track id \(id) of library playlist 1)")
                await confirmStart(title: title, seeked: false, volume: volume, target: target)
            case .catalog(let id):
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return }
                let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
                script.send("open location \"music://music.apple.com/\(storefront)/song/\(id)\"")
                script.send("stop")
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
                    script.send("stop")
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
