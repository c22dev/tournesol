//
//  MusicPlayerSource.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AVFoundation
import MediaPlayer
import OSLog
import UIKit

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "Transfer")

final class MusicPlayerSource: LocalPlayer {
    var onChange: (() -> Void)?
    private(set) var state = PlaybackState.idle
    private(set) var artwork: Artwork?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let session = AVAudioSession.sharedInstance()
    private let volume = VolumeService.shared
    private var observers: [NSObjectProtocol] = []
    private var resolvedKeys: Set<String> = []
    private var catalogIDs: [String: String] = [:]
    /// Queued songs the controller removed. The system player can't drop one, so each is jumped over when it comes up.
    private var skipped: [String] = []

    init() {
        player.beginGeneratingPlaybackNotifications()

        let names: [Notification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
            AVAudioSession.routeChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        volume.onChange = { [weak self] in self?.refresh() }
        Task { [weak self] in
            await CatalogLookup.requestAuthorization()
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        if let item = player.nowPlayingItem, !skipped.isEmpty {
            let signature = TrackReference(catalogID: nil, title: item.title, artist: item.artist, album: item.albumTitle, duration: 0).signature
            if let index = skipped.firstIndex(of: signature) {
                skipped.remove(at: index)
                player.skipToNextItem()
                return
            }
        }
        volume.poll()
        var next = PlaybackState()
        next.volume = volume.current
        next.output = currentOutput()

        if let item = player.nowPlayingItem {
            let key = item.persistentID != 0 ? String(item.persistentID) : item.playbackStoreID
            next.title = item.title
            next.artist = item.artist
            next.album = item.albumTitle
            next.duration = item.playbackDuration
            next.elapsed = player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0
            next.isPlaying = player.playbackState == .playing
            let storeID = item.playbackStoreID
            next.catalogID = storeID.isEmpty || storeID == "0" ? catalogIDs[key] : storeID
            resolve(item, key: key, track: next.track)
            next.artworkID = artwork?.id == key ? key : nil
        }
        next.loadedSignature = loadedSignature
        next.shuffle = player.shuffleMode != .off && player.shuffleMode != .default
        next.repeatMode = switch player.repeatMode {
        case .one: .one
        case .all: .all
        default: .off
        }

        state = next
        onChange?()
    }

    func perform(_ command: Command) {
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .togglePlayPause: player.playbackState == .playing ? player.pause() : player.play()
        case .next: player.skipToNextItem()
        case .previous: player.currentPlaybackTime > 3 ? player.skipToBeginning() : player.skipToPreviousItem()
        case .seek(let position): player.currentPlaybackTime = position
        case .setVolume(let value): volume.set(value)
        case .loadTrack(let track, let position, let upcoming): load(track, at: position, upcoming: upcoming)
        case .enqueue(let track, let next): enqueue([track], next: next)
        case .enqueueAll(let tracks, let next): enqueue(tracks, next: next)
        case .setQueue(let tracks): rebuildQueue(upcoming: tracks)
        case .setShuffle(let on): player.shuffleMode = on ? .songs : .off
        case .setRepeat(let mode): player.repeatMode = switch mode {
        case .off: .none
        case .all: .all
        case .one: .one
        }
        case .setLiked, .setAirPlay: break
        case .startLoaded(let position): startLoaded(at: position)
        case .handOff: player.pause()
        case .release: release()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            refresh()
        }
    }

    private func resolve(_ item: MPMediaItem, key: String, track: TrackReference) {
        let needsArtwork = artwork?.id != key
        guard needsArtwork || track.catalogID == nil, resolvedKeys.insert(key).inserted else { return }

        if needsArtwork,
           let image = item.artwork?.image(at: CGSize(width: 600, height: 600)),
           let data = image.jpegData(compressionQuality: 0.9),
           let thumbnail = ArtworkEncoding.thumbnail(from: data) {
            artwork = Artwork(id: key, data: thumbnail)
            if track.catalogID != nil { return }
        }

        let wantsArtwork = artwork?.id != key
        Task {
            let result = await CatalogLookup.resolve(track, needsArtwork: wantsArtwork)
            if let id = result.catalogID { catalogIDs[key] = id }
            if let data = result.artwork, artwork?.id != key { artwork = Artwork(id: key, data: data) }
            refresh()
        }
    }

    private enum Located {
        case library(MPMediaItem)
        case catalog(String)
    }

    private var prepared: [String: Located] = [:]
    private var preparing: Set<String> = []
    private var loading: Task<Bool, Never>?
    private var loadedSignature: String?

    func prepare(_ track: TrackReference) {
        let signature = track.signature
        guard prepared[signature] == nil, preparing.insert(signature).inserted else { return }
        Task {
            if let located = await locate(track) {
                prepared[signature] = located
                log.debug("prepared \(track.title ?? "?", privacy: .public)")
            }
            preparing.remove(signature)
        }
    }

    private func locate(_ track: TrackReference) async -> Located? {
        if let item = libraryItem(matching: track, threshold: TrackMatcher.acceptable, requireAlbum: true) {
            return .library(item)
        }
        if let catalogID = await catalogID(for: track) {
            return .catalog(catalogID)
        }
        if let item = libraryItem(matching: track, threshold: TrackMatcher.loose, requireAlbum: false) {
            return .library(item)
        }
        return nil
    }

    func upcomingTracks() async -> [TrackReference] {
        var pending = skipped
        return queuedTracks().filter { track in
            guard let index = pending.firstIndex(of: track.signature) else { return true }
            pending.remove(at: index)
            return false
        }
    }

    private func queuedTracks() -> [TrackReference] {
        let countSelector = NSSelectorFromString("numberOfItems")
        let itemSelector = NSSelectorFromString("nowPlayingItemAtIndex:")
        guard player.responds(to: countSelector), player.responds(to: itemSelector) else { return [] }
        typealias Count = @convention(c) (AnyObject, Selector) -> UInt
        typealias Item = @convention(c) (AnyObject, Selector, UInt) -> MPMediaItem?
        let count = unsafeBitCast(player.method(for: countSelector), to: Count.self)(player, countSelector)
        let itemAt = unsafeBitCast(player.method(for: itemSelector), to: Item.self)
        let current = UInt(player.indexOfNowPlayingItem)
        guard current != UInt(NSNotFound), count > current + 1 else { return [] }
        return (current + 1..<min(count, current + 26)).compactMap { index in
            guard let item = itemAt(player, itemSelector, index) else { return nil }
            let storeID = item.playbackStoreID
            return TrackReference(catalogID: storeID.isEmpty || storeID == "0" ? nil : storeID, title: item.title, artist: item.artist, album: item.albumTitle, duration: item.playbackDuration)
        }
    }

    private func enqueue(_ tracks: [TrackReference], next: Bool) {
        Task {
            let ids = await catalogIDs(for: tracks).filter { $0.allSatisfy(\.isNumber) }
            guard !ids.isEmpty else { return }
            let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: ids)
            if player.nowPlayingItem == nil {
                player.setQueue(with: descriptor)
                player.play()
            } else if next {
                player.prepend(descriptor)
            } else {
                player.append(descriptor)
            }
            refresh()
        }
    }

    /// The signatures dropped when `target` is `existing` with some songs taken out, or nil if the order changed or something was added.
    private static func removals(from existing: [TrackReference], to target: [TrackReference]) -> [String]? {
        var kept = 0
        var removed: [String] = []
        for track in existing {
            if kept < target.count, track.signature == target[kept].signature { kept += 1 } else { removed.append(track.signature) }
        }
        return kept == target.count ? removed : nil
    }

    /// Reordering or adding needs a rebuild: the queue is replaced around the current song and position.
    private func rebuildQueue(upcoming tracks: [TrackReference]) {
        guard state.hasTrack else { return }
        let current = state.track
        let position = state.elapsed(at: .now)
        let wasPlaying = state.isPlaying
        Task {
            let existing = await upcomingTracks()
            guard existing.map(\.signature) != tracks.map(\.signature) else { return }
            if !tracks.isEmpty, let removed = Self.removals(from: existing, to: tracks) {
                skipped += removed
                return
            }
            skipped = []
            load(current, at: position, upcoming: tracks)
            if wasPlaying { startLoaded(at: position) }
        }
    }

    private func catalogIDs(for tracks: [TrackReference]) async -> [String] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, track) in tracks.enumerated() {
                group.addTask {
                    if let id = track.catalogID, id.allSatisfy(\.isNumber) { return (index, id) }
                    return (index, await CatalogLookup.resolve(track, needsArtwork: false).catalogID)
                }
            }
            var found: [Int: String] = [:]
            for await (index, id) in group { found[index] = id }
            return tracks.indices.compactMap { found[$0] }
        }
    }

    private var loadGeneration = 0

    /// Looks the queue up while the song prepares, then adds it behind the song, unless another load has begun since.
    private func restOfQueue(_ tracks: [TrackReference], generation: Int) {
        guard !tracks.isEmpty else { return }
        Task {
            let ids = await catalogIDs(for: tracks)
            guard generation == loadGeneration, !ids.isEmpty else { return }
            player.append(MPMusicPlayerStoreQueueDescriptor(storeIDs: ids))
            log.debug("queued \(ids.count) more behind the loaded song")
            refresh()
        }
    }

    private func load(_ track: TrackReference, at position: TimeInterval, upcoming: [TrackReference]) {
        skipped = []
        loadGeneration += 1
        loadedSignature = nil
        loading?.cancel()
        loading = Task {
            var located = prepared[track.signature]
            log.debug("load \(track.title ?? "?", privacy: .public) prepared=\(located != nil) upcoming=\(upcoming.count)")
            if located == nil { located = await locate(track) }
            guard let located, !Task.isCancelled else {
                log.error("no match found")
                return false
            }
            switch located {
            case .library(let item):
                let rest = upcoming.compactMap { libraryItem(matching: $0, threshold: TrackMatcher.acceptable, requireAlbum: false) }
                player.setQueue(with: MPMediaItemCollection(items: [item] + rest))
            case .catalog(let id):
                // the song starts without waiting for the rest of the queue to be looked up
                player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: [id]))
                restOfQueue(upcoming, generation: loadGeneration)
            }
            try? await player.prepareToPlay()
            player.currentPlaybackTime = position
            loadedSignature = track.signature
            refresh()
            return true
        }
    }

    private func startLoaded(at position: TimeInterval) {
        let received = ContinuousClock.now
        let target = { position + (ContinuousClock.now - received) / .seconds(1) }
        Task {
            guard await loading?.value == true else { return }
            loading = nil
            player.currentPlaybackTime = target()
            player.play()
            loadedSignature = nil

            for _ in 0..<20 where player.playbackState != .playing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            refresh()
            try? await Task.sleep(for: .seconds(1))
            if abs(player.currentPlaybackTime - target()) > 2 {
                player.currentPlaybackTime = target()
            }
            refresh()
        }
    }

    private func release() {
        skipped = []
        player.stop()
        let empty = MPMediaQuery.songs()
        empty.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: UInt64(0)), forProperty: MPMediaItemPropertyPersistentID))
        player.setQueue(with: empty)
        player.stop()
    }

    private func catalogID(for track: TrackReference) async -> String? {
        if let id = track.catalogID { return id }
        return await CatalogLookup.resolve(track, needsArtwork: false, allowLooseMatch: true).catalogID
    }

    private func libraryItem(matching track: TrackReference, threshold: Int, requireAlbum: Bool) -> MPMediaItem? {
        guard let title = track.title else { return nil }
        let query = MPMediaQuery.songs()
        if threshold < TrackMatcher.acceptable {
            query.addFilterPredicate(MPMediaPropertyPredicate(value: title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression), forProperty: MPMediaItemPropertyTitle, comparisonType: .contains))
        } else {
            query.addFilterPredicate(MPMediaPropertyPredicate(value: title, forProperty: MPMediaItemPropertyTitle))
        }
        let candidates = (query.items ?? []).map { item in
            (item, TrackMatcher.score(title: item.title ?? "", artist: item.artist ?? "", album: item.albumTitle, duration: item.playbackDuration, against: track))
        }
        let best = candidates.max { $0.1 < $1.1 }
        guard let best, best.1 >= threshold else { return nil }
        if requireAlbum, let album = track.album, TrackMatcher.normalize(best.0.albumTitle ?? "") != TrackMatcher.normalize(album) { return nil }
        return best.0
    }

    private func currentOutput() -> AudioOutput? {
        guard let port = session.currentRoute.outputs.first else { return nil }
        let kind: AudioOutput.Kind = switch port.portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: AudioOutput.kind(forName: port.portName, fallback: .bluetooth)
        case .headphones, .usbAudio: .headphones
        case .airPlay: .airPlay
        case .HDMI: .display
        case .carAudio: .car
        default: .builtIn
        }
        return AudioOutput(name: port.portName, kind: kind)
    }
}
