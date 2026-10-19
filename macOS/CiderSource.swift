//
//  CiderSource.swift
//  Tournesol
//

import AppKit
import OSLog

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "Cider")

/// Plays through Cider's local REST API (http://127.0.0.1:10767). Access is granted once from a prompt inside Cider.
final class CiderSource: LocalPlayer {
    static let bundleID = "sh.cider.genten.mac"
    static let tokenKey = "ciderToken"

    enum Status: Equatable {
        case notRunning, waitingForApproval, denied, connected
    }

    var onChange: (() -> Void)?
    private(set) var state = PlaybackState.idle
    private(set) var artwork: Artwork?
    private(set) var status = Status.notRunning

    var isRunning: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first != nil }

    private let audio = SystemAudio()
    private let authSession = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        return configuration
    }())
    private var authorizing: Task<Void, Never>?
    private var authBlockedUntil = ContinuousClock.now
    private let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        return configuration
    }())
    private var pollTask: Task<Void, Never>?
    private var artworkURL: String?
    private var artworkCache: [String: Data] = [:]
    private var loaded: (track: TrackReference, id: String)?
    private var loading: Task<Void, Never>?
    private var pendingUpcoming: [TrackReference] = []
    private var queueItems: [QueueItem] = []
    private var current: NowPlaying?
    private var catalogIDs: [String: String] = [:]

    private struct NowPlaying: Equatable {
        var title: String
        var artist: String?
        var album: String?
        var duration: TimeInterval
        var elapsed: TimeInterval
        /// When `elapsed` was true: it is only a position at that moment.
        var polledAt = Date.now
        var catalogID: String?
        var artworkTemplate: String?
        var shuffle: Bool
        var repeatMode: RepeatMode
        var liked: Bool
    }

    struct QueueItem {
        let track: TrackReference
        var isCurrent: Bool
    }

    init() {
        audio.onChange = { [weak self] in self?.publish() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                guard let self else { return }
                let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: pollInterval) }
                self.sleeper = sleeper
                await sleeper.value
            }
        }
    }

    deinit { pollTask?.cancel() }

    private var sleeper: Task<Void, Never>?
    /// Counts changes sent to Cider, so a poll that began before one can't undo it.
    private var commandEpoch = 0
    private var lastPolled = ContinuousClock.now

    /// The system's now-playing stream says when something changes, so polling is only a fallback: slower still while Music is the one in use.
    var isPassive = false {
        didSet {
            guard oldValue != isPassive, !isPassive else { return }
            sleeper?.cancel()
        }
    }

    private var pollInterval: Duration {
        guard isRunning else { return .seconds(5) }
        return isPassive ? .seconds(15) : .seconds(5)
    }

    private var lastNudge: (client: String, title: String?, rate: Double, elapsed: Double, at: ContinuousClock.Instant)?

    /// Called with each update from the now-playing stream. Only a change worth a request wakes the poll.
    func nudge(_ info: NowPlayingStream.Info) {
        guard isRunning else { return }
        defer { lastNudge = (info.client, info.title, info.rate ?? 0, info.elapsed ?? 0, .now) }
        if let last = lastNudge, last.client == info.client, last.title == info.title, last.rate == (info.rate ?? 0) {
            // same song, same state: only a seek is news
            let expected = last.elapsed + (last.rate > 0 ? (ContinuousClock.now - last.at) / .seconds(1) * last.rate : 0)
            guard abs((info.elapsed ?? 0) - expected) > 1.5 else { return }
        }
        guard ContinuousClock.now - lastPolled > .milliseconds(300) else { return }
        sleeper?.cancel()
    }

    func refresh() { publish() }
    func prepare(_ track: TrackReference) {}

    func upcomingTracks() async -> [TrackReference] {
        await refreshQueue()
        return upcoming
    }

    private var upcoming: [TrackReference] {
        guard let index = queueItems.firstIndex(where: \.isCurrent) else { return [] }
        return queueItems.dropFirst(index + 1).map(\.track)
    }

    // MARK: Requests

    private var token: String? {
        UserDefaults.standard.string(forKey: Self.tokenKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func requestData(_ path: String, body: [String: Any]? = nil, post: Bool = false) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:10767/api/v1/playback" + path) else { return nil }
        var request = URLRequest(url: url)
        if post || body != nil {
            commandEpoch += 1
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body ?? [:])
        }
        if let token { request.setValue(token, forHTTPHeaderField: "apptoken") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 403 {
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            authorize()
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        setStatus(.connected)
        return data
    }

    private func request(_ path: String, body: [String: Any]? = nil, post: Bool = false) async -> Any? {
        guard let data = await requestData(path, body: body, post: post) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
    }

    private func send(_ path: String, body: [String: Any]? = nil) {
        // polls already under way began before this and can't speak for it
        commandEpoch += 1
        Task { [weak self] in
            _ = await self?.request(path, body: body, post: true)
            await self?.poll()
            // Cider takes a moment to settle; look again until it agrees with what was asked
            for delay in [350, 800] {
                guard self?.playingIntent != nil else { return }
                try? await Task.sleep(for: .milliseconds(delay))
                await self?.poll()
            }
        }
    }

    /// Asks Cider for access. Cider shows an Allow/Deny prompt and answers with a token.
    func authorize(userInitiated: Bool = false) {
        guard authorizing == nil, userInitiated || ContinuousClock.now >= authBlockedUntil else { return }
        setStatus(.waitingForApproval)
        authorizing = Task { [weak self] in
            guard let self else { return }
            defer { authorizing = nil }
            var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:10767/api/v2/auth/request")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                "app_name": "Tournesol",
                "scopes": ["playback", "queue", "library", "audio"]
            ])
            let response = try? await authSession.data(for: urlRequest)
            let json = response.flatMap { try? JSONSerialization.jsonObject(with: $0.0) } as? [String: Any]
            let token = (json?["token"] as? String) ?? ((json?["data"] as? [String: Any])?["token"] as? String)
            if let token, !token.isEmpty {
                UserDefaults.standard.set(token, forKey: Self.tokenKey)
                log.info("Cider access granted")
                setStatus(.connected)
                await poll()
            } else {
                log.error("Cider access not granted: \(String(describing: json), privacy: .public)")
                // a few denials get this app banned for a while, so don't ask again by itself
                authBlockedUntil = .now + .seconds(600)
                setStatus(.denied)
            }
        }
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        onChange?()
    }

    // MARK: State

    private func poll() async {
        lastPolled = .now
        guard isRunning else {
            current = nil
            setStatus(.notRunning)
            publish()
            return
        }
        let epoch = commandEpoch
        async let playingReply = requestData("/is-playing")
        async let infoReply = requestData("/now-playing")
        let (playingData, infoData) = await (playingReply, infoReply)
        let playingJSON = playingData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let infoJSON = infoData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        // a change was sent meanwhile; its own poll follows
        guard epoch == commandEpoch else { return }
        guard let playing = (playingJSON as? [String: Any])?["is_playing"] as? Bool else {
            current = nil
            publish()
            return
        }
        current = (infoJSON as? [String: Any])?["info"].flatMap { $0 as? [String: Any] }.flatMap(Self.parse)
        var reported = playing
        if let intent = playingIntent {
            if reported == intent.value || ContinuousClock.now > intent.expires { playingIntent = nil } else { reported = intent.value }
        }
        publishPlaying(reported)
    }

    private nonisolated static func parse(_ info: [String: Any]) -> NowPlaying? {
        guard let title = info["name"] as? String, !title.isEmpty else { return nil }
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let params = info["playParams"] as? [String: Any]
        let ids = [params?["catalogId"], params?["id"]].compactMap { value -> String? in
            if let string = value as? String { return string }
            return (value as? NSNumber)?.stringValue
        }
        return NowPlaying(
            title: title,
            artist: text("artistName"),
            album: text("albumName"),
            duration: ((info["durationInMillis"] as? Double) ?? 0) / 1000,
            elapsed: (info["currentPlaybackTime"] as? Double) ?? 0,
            catalogID: ids.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
            artworkTemplate: (info["artwork"] as? [String: Any])?["url"] as? String,
            shuffle: (info["shuffleMode"] as? Int ?? 0) != 0,
            repeatMode: [0: .off, 1: .one, 2: .all][info["repeatMode"] as? Int ?? 0] ?? .off,
            liked: info["inFavorites"] as? Bool ?? false
        )
    }

    private var playingNow = false
    /// What the user just asked for. Cider's state lags a command by a fraction of a second, and a poll in that gap must not undo it.
    private var playingIntent: (value: Bool, expires: ContinuousClock.Instant)?

    private func publishPlaying(_ playing: Bool) {
        playingNow = playing
        publish()
    }

    private func publish() {
        var next = PlaybackState()
        next.volume = audio.volume
        next.output = audio.output
        if let current {
            next.title = current.title
            next.artist = current.artist
            next.album = current.album
            next.duration = current.duration
            next.elapsed = min(current.duration, current.elapsed + (playingNow ? Date.now.timeIntervalSince(current.polledAt) : 0))
            next.timestamp = .now
            next.isPlaying = playingNow
            next.shuffle = current.shuffle
            next.repeatMode = current.repeatMode
            next.isLiked = current.liked
            let key = next.track.signature
            next.catalogID = current.catalogID ?? catalogIDs[key]
            if let data = artworkCache[key] {
                if artwork?.id != key { artwork = Artwork(id: key, data: data) }
                next.artworkID = key
            } else {
                loadArtwork(for: key, template: current.artworkTemplate)
            }
            if current.catalogID == nil, catalogIDs[key] == nil { resolveID(key: key, track: next.track) }
        }
        next.loadedSignature = loaded?.track.signature
        // a steady song keeps the state fresh without telling anyone
        let changed = next.differs(from: state)
        state = next
        if changed { onChange?() }
    }

    private var resolving: Set<String> = []

    private func resolveID(key: String, track: TrackReference) {
        guard resolving.insert(key).inserted else { return }
        Task { [weak self] in
            let result = await CatalogLookup.resolve(track, needsArtwork: false)
            if let id = result.catalogID { self?.catalogIDs[key] = id }
            self?.publish()
        }
    }

    private func loadArtwork(for key: String, template: String?) {
        guard let template, artworkURL != template + key else { return }
        artworkURL = template + key
        let address = template.replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600")
        guard let url = URL(string: address) else { return }
        Task { [weak self] in
            guard let self, let (data, _) = try? await session.data(from: url), let thumbnail = ArtworkEncoding.thumbnail(from: data) else { return }
            if artworkCache.count > 8 { artworkCache.removeAll() }
            artworkCache[key] = thumbnail
            publish()
        }
    }

    private func refreshQueue() async {
        guard let items = await request("/queue") as? [[String: Any]] else {
            queueItems = []
            return
        }
        queueItems = items.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any], let title = attributes["name"] as? String else { return nil }
            let id = (item["id"] as? String).flatMap { !$0.isEmpty && $0.allSatisfy(\.isNumber) ? $0 : nil }
            let track = TrackReference(
                catalogID: id,
                title: title,
                artist: (attributes["artistName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                album: (attributes["albumName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                duration: ((attributes["durationInMillis"] as? Double) ?? 0) / 1000
            )
            return QueueItem(track: track, isCurrent: ((item["_state"] as? [String: Any])?["current"] as? Int) == 2)
        }
        // this Cider doesn't flag the playing item, so find it by what is playing
        if !queueItems.contains(where: \.isCurrent), let current,
           let index = queueItems.firstIndex(where: { $0.track.catalogID != nil && $0.track.catalogID == current.catalogID })
               ?? queueItems.firstIndex(where: { TrackMatcher.sameSong($0.track.title, current.title) }) {
            queueItems[index].isCurrent = true
        }
    }

    // MARK: Commands

    func perform(_ command: Command) {
        switch command {
        case .play:
            setPlaying(true)
            send("/play")
        case .pause:
            setPlaying(false)
            send("/pause")
        case .togglePlayPause:
            // an explicit command: a toggle would undo itself if Cider already changed state
            let play = !playingNow
            setPlaying(play)
            send(play ? "/play" : "/pause")
        case .next: send("/next")
        case .previous: send("/previous")
        case .seek(let position):
            freezePosition()
            current?.elapsed = position
            send("/seek", body: ["position": position])
        case .setVolume(let volume): audio.volume = volume
        case .loadTrack(let track, _, let upcoming):
            load(track)
            pendingUpcoming = upcoming
        case .startLoaded(let position):
            start(at: position)
        case .enqueue(let track, let next): Task { await enqueue([track], next: next) }
        case .enqueueAll(let tracks, let next): Task { await enqueue(tracks, next: next) }
        case .setQueue(let tracks): Task { await replaceQueue(with: tracks) }
        case .setShuffle(let on): Task { await setShuffle(on) }
        case .setRepeat(let mode): Task { await setRepeat(mode) }
        case .setLiked(let liked):
            current?.liked = liked
            send("/set-rating", body: ["rating": liked ? 1 : 0])
        case .setAirPlay: break
        case .handOff: Task { await fadeOutAndPause() }
        case .release:
            loading?.cancel()
            loaded = nil
            pendingUpcoming = []
        }
        publish()
    }

    /// Shown at once; the next poll confirms it.
    private func setPlaying(_ playing: Bool) {
        freezePosition()
        playingNow = playing
        playingIntent = (playing, .now + .seconds(2))
    }

    /// Settles the position to now, before something changes how it advances.
    private func freezePosition() {
        guard var now = current else { return }
        if playingNow { now.elapsed = min(now.duration, now.elapsed + Date.now.timeIntervalSince(now.polledAt)) }
        now.polledAt = .now
        current = now
    }

    private func songID(for track: TrackReference) async -> String? {
        if let id = track.catalogID, !id.isEmpty, id.allSatisfy(\.isNumber) { return id }
        let id = await CatalogLookup.resolve(track, needsArtwork: false, allowLooseMatch: true).catalogID
        return id.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    /// Finds the song ahead of time, so the start itself has nothing left to look up. Only a found song counts as loaded.
    private func load(_ track: TrackReference) {
        loading?.cancel()
        loaded = nil
        loading = Task { [weak self] in
            guard let self, let id = await songID(for: track), !Task.isCancelled else {
                log.error("could not locate \(track.title ?? "?", privacy: .public)")
                return
            }
            loaded = (track, id)
            publish()
        }
    }

    private func start(at position: TimeInterval) {
        let received = ContinuousClock.now
        let target = { position + (ContinuousClock.now - received) / .seconds(1) }
        Task { [weak self] in
            guard let self else { return }
            await loading?.value
            loading = nil
            guard let (track, id) = loaded, let title = track.title else {
                log.error("startLoaded: nothing loaded")
                return
            }
            loaded = nil
            let upcoming = pendingUpcoming
            pendingUpcoming = []

            // start muted at the right place, so the first seconds are never heard from the wrong spot
            let volume = await currentVolume()
            _ = await request("/volume", body: ["volume": 0])
            defer { Task { _ = await self.request("/volume", body: ["volume": volume]) } }
            guard await request("/play-item", body: ["type": "songs", "id": id]) != nil else { return }

            var seeked = false
            var pressedPlay = false
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(150))
                await poll()
                guard TrackMatcher.sameSong(state.title, title) else { continue }
                if !seeked {
                    // Cider ignores a seek until the audio has really begun
                    guard state.elapsed > 0 else { continue }
                    _ = await request("/seek", body: ["position": target()])
                    seeked = true
                    continue
                }
                if !state.isPlaying {
                    if !pressedPlay {
                        _ = await request("/play", post: true)
                        pressedPlay = true
                    }
                    continue
                }
                // seeking can lag behind a freshly started song
                guard abs(state.elapsed(at: .now) - target()) < 2 else {
                    _ = await request("/seek", body: ["position": target()])
                    continue
                }
                await fade(to: volume)
                if !upcoming.isEmpty { await enqueue(upcoming, next: true) }
                return
            }
            log.error("start of \(title, privacy: .public) was not confirmed")
        }
    }

    private func currentVolume() async -> Double {
        let volume = ((await request("/volume") as? [String: Any])?["volume"] as? Double) ?? 1
        // a volume left at zero by an interrupted fade must not be restored
        return volume > 0.05 ? volume : 1
    }

    private func fade(to end: Double) async {
        for step in 1...5 {
            _ = await request("/volume", body: ["volume": end * Double(step) / 5])
            try? await Task.sleep(for: .milliseconds(55))
        }
    }

    private func enqueue(_ tracks: [TrackReference], next: Bool) async {
        // play-next puts each song first, so the batch goes in reverse to keep its order
        for track in next ? tracks.reversed() : tracks {
            guard let id = await songID(for: track) else { continue }
            _ = await request(next ? "/play-next" : "/play-later", body: ["type": "songs", "id": id])
        }
        await refreshQueue()
        await poll()
    }

    private func replaceQueue(with tracks: [TrackReference]) async {
        await refreshQueue()
        guard let current = queueItems.firstIndex(where: \.isCurrent) else { return }
        if upcoming.map(\.signature) == tracks.map(\.signature) { return }
        // indices are 0-based and include history
        for index in stride(from: queueItems.count - 1, through: current + 1, by: -1) {
            _ = await request("/queue/remove-by-index", body: ["index": index])
        }
        await enqueue(tracks, next: false)
    }

    private func setShuffle(_ on: Bool) async {
        guard let current, current.shuffle != on else { return }
        _ = await request("/toggle-shuffle", post: true)
        try? await Task.sleep(for: .milliseconds(250))
        await poll()
    }

    private func setRepeat(_ mode: RepeatMode) async {
        // Cider cycles off -> all -> one -> off through toggle-repeat
        for _ in 0..<3 {
            guard let current, current.repeatMode != mode else { break }
            _ = await request("/toggle-repeat", post: true)
            try? await Task.sleep(for: .milliseconds(250))
            await poll()
        }
    }

    private func fadeOutAndPause() async {
        let start = await currentVolume()
        for step in 1...5 {
            _ = await request("/volume", body: ["volume": start * Double(5 - step) / 5])
            try? await Task.sleep(for: .milliseconds(55))
        }
        // report the pause now: Cider still says "playing" for a moment after it, and the other device is waiting to hear that it let go
        setPlaying(false)
        publish()
        _ = await request("/pause", post: true)
        _ = await request("/volume", body: ["volume": start])
        await poll()
        for delay in [350, 800] {
            guard playingIntent != nil else { return }
            try? await Task.sleep(for: .milliseconds(delay))
            await poll()
        }
    }
}
