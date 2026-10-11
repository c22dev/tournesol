//
//  NowPlayingStream.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AppKit
import OSLog

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "NowPlaying")

final class NowPlayingStream {
    nonisolated struct Info: Decodable, Equatable, Sendable {
        var client: String
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var catalogID: Int?
        var timestamp: Double?
        var artworkLength: Int?
        var artwork: String?
        var itemID: String?
        var queue: [QueueItem]?
    }

    /// An entry of Music's own playback queue, starting at the current track.
    nonisolated struct QueueItem: Decodable, Equatable, Sendable {
        var id: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var catalogID: Int?

        private enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration, catalogID
        }

        // the store id comes as a string; a badly typed field shouldn't drop the whole line
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            artist = try? container.decodeIfPresent(String.self, forKey: .artist)
            album = try? container.decodeIfPresent(String.self, forKey: .album)
            duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .catalogID) {
                catalogID = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .catalogID) {
                catalogID = Int(text)
            }
        }
    }

    var onUpdate: ((Info) -> Void)?
    private(set) var lastUpdate: ContinuousClock.Instant?
    private var process: Process?
    private var buffer = Data()
    private var failures = 0

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            log.error("helper failed to launch: \(error.localizedDescription, privacy: .public)")
            restart()
        }
    }

    private func restart() {
        failures += 1
        guard failures < 6 else {
            log.error("helper keeps exiting, giving up")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let info = try? JSONDecoder().decode(Info.self, from: line) else { continue }
            failures = 0
            lastUpdate = .now
            onUpdate?(info)
        }
    }

    private static let script = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        const Request = $.NSClassFromString('MRNowPlayingRequest')
        const stdout = $.NSFileHandle.fileHandleWithStandardOutput
        const prefix = 'kMRMediaRemoteNowPlayingInfo'
        const controller = (() => {
          try {
            const destination = $.NSClassFromString('MRDestination').localDestination
            const configuration = $.NSClassFromString('MRNowPlayingControllerConfiguration').alloc.initWithDestination(destination)
            const request = $.NSClassFromString('MRPlaybackQueueRequest').defaultPlaybackQueueRequest
            request.setIncludeMetadata(true)
            request.setIncludeInfo(true)
            request.setLocation(0)
            request.setLength(60)
            configuration.setPlaybackQueueRequest(request)
            configuration.setRequestPlaybackQueue(true)
            const created = $.NSClassFromString('MRNowPlayingController').alloc.initWithConfiguration(configuration)
            created.beginLoadingUpdates
            return created
          } catch (e) { return null }
        })()
        function queueSnapshot() {
          try {
            const items = controller.response.playbackQueue.contentItems
            if (items.isNil()) return null
            const out = []
            for (let i = 0; i < items.count; i++) {
              const item = items.objectAtIndex(i)
              const md = item.metadata
              out.push({
                id: ObjC.unwrap(item.identifier),
                title: ObjC.unwrap(md.title), artist: ObjC.unwrap(md.trackArtistName), album: ObjC.unwrap(md.albumName),
                duration: md.duration, catalogID: ObjC.unwrap(md.iTunesStoreIdentifier)
              })
            }
            return out
          } catch (e) { return null }
        }
        function snapshot() {
          const result = { client: '' }
          try {
            result.client = ObjC.unwrap(Request.localNowPlayingPlayerPath.client.bundleIdentifier) || ''
            const info = Request.localNowPlayingItem.nowPlayingInfo
            if (info.isNil()) return result
            const get = (k) => { const v = info.objectForKey(prefix + k); return v.isNil() ? null : ObjC.deepUnwrap(v) }
            result.itemID = ObjC.unwrap(Request.localNowPlayingItem.identifier) || null
            result.title = get('Title'); result.artist = get('Artist'); result.album = get('Album')
            result.duration = get('Duration'); result.elapsed = get('ElapsedTime'); result.rate = get('PlaybackRate')
            result.catalogID = get('iTunesStoreIdentifier') || null
            try { const ts = info.objectForKey(prefix + 'Timestamp'); result.timestamp = ts.isNil() ? null : ts.timeIntervalSince1970 } catch (e) {}
            try { const art = info.objectForKey(prefix + 'ArtworkData'); if (!art.isNil()) { result.artworkLength = art.length; result._art = art } } catch (e) {}
          } catch (e) {}
          return result
        }
        let last = ''
        let lastArt = ''
        let lastQueue = null
        let tick = 0
        let lastEmit = 0
        while (true) {
          const snap = snapshot()
          if (controller && snap.client === 'com.apple.Music' && tick++ % 4 === 0) lastQueue = queueSnapshot()
          snap.queue = snap.client === 'com.apple.Music' ? lastQueue : null
          const art = snap._art
          delete snap._art
          const artKey = (snap.title || '') + '|' + (snap.artworkLength || 0)
          const line = JSON.stringify(snap)
          if (line !== last || (art && artKey !== lastArt) || Date.now() - lastEmit > 5000) {
            if (art && artKey !== lastArt) { snap.artwork = ObjC.unwrap(art.base64EncodedStringWithOptions(0)); lastArt = artKey }
            stdout.writeData($(JSON.stringify(snap) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding))
            last = line
            lastEmit = Date.now()
          }
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25))
        }
        """
}

nonisolated final class MusicScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ch.cclerc.Tournesol.music-script", qos: .userInitiated)

    func send(_ command: String) {
        queue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Music\" to \(command)")?.executeAndReturnError(&error)
            if let error { log.error("script failed [\(command, privacy: .public)]: \(String(describing: error), privacy: .public)") }
        }
    }

    /// A change to Music's queue: remove (129), move (130) or play (131).
    struct QueueOperation: Encodable, Sendable {
        var command: Int
        var id: String
        var after: String?

        static func remove(_ id: String) -> Self { Self(command: 129, id: id) }
        static func move(_ id: String, after: String) -> Self { Self(command: 130, id: id, after: after) }
        static func play(_ id: String) -> Self { Self(command: 131, id: id) }
    }

    func editQueue(_ operations: [QueueOperation]) {
        guard !operations.isEmpty, let data = try? JSONEncoder().encode(operations), let json = String(data: data, encoding: .utf8) else { return }
        runJXA(Self.queueEditScript, arguments: [json])
    }

    /// Adds songs next, or right behind the queue item `after`.
    func insertIntoQueue(storeIDs: [String], next: Bool, after anchor: String? = nil) {
        let anchor = next ? nil : anchor
        sendQueuePayload(command: 125, storeIDs: storeIDs, immediate: false, position: anchor == nil ? 0 : 3, after: anchor)
    }

    /// Replaces the queue and starts the first song.
    func startPlayback(storeIDs: [String]) {
        sendQueuePayload(command: 122, storeIDs: storeIDs, immediate: true, position: nil, after: nil)
    }

    /// Music aborts on any payload shape other than this plist.
    private func sendQueuePayload(command: Int, storeIDs: [String], immediate: Bool, position: Int?, after anchor: String?) {
        let payload: [String: Any] = ["PQty": 3, "PQst": storeIDs, "PQip": immediate, "PQri": 0, "PQtr": 0, "PQts": 0]
        guard !storeIDs.isEmpty, storeIDs.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) else { return }
        runJXA(Self.queuePayloadScript, arguments: [data.base64EncodedString(), position.map(String.init) ?? "", String(command), anchor ?? ""])
    }

    private func runJXA(_ source: String, arguments: [String]) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log.error("queue script failed to launch: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let queuePayloadScript = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        function run(argv) {
          const Request = $.NSClassFromString('MRNowPlayingRequest')
          const request = Request.alloc.initWithPlayerPath(Request.localNowPlayingPlayerPath)
          const options = $.NSMutableDictionary.dictionary
          options.setObjectForKey($.NSData.alloc.initWithBase64EncodedStringOptions(argv[0], 0), 'kMRMediaRemoteOptionSystemAppPlaybackQueueData')
          if (argv[1] !== '') options.setObjectForKey($.NSNumber.numberWithInt(parseInt(argv[1])), 'kMRMediaRemoteOptionPlaybackQueueInsertionPosition')
          if (argv[3]) options.setObjectForKey(argv[3], 'kMRMediaRemoteOptionInsertAfterContentItemID')
          request.sendCommandOptionsQueueCompletion(parseInt(argv[2]), options, $(), $())
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.5))
        }
        """

    private static let queueEditScript = """
        ObjC.import('Foundation')
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
        function run(argv) {
          const Request = $.NSClassFromString('MRNowPlayingRequest')
          const request = Request.alloc.initWithPlayerPath(Request.localNowPlayingPlayerPath)
          for (const op of JSON.parse(argv[0])) {
            const options = $.NSMutableDictionary.dictionary
            options.setObjectForKey(op.id, 'kMRMediaRemoteOptionContentItemID')
            if (op.after) options.setObjectForKey(op.after, 'kMRMediaRemoteOptionInsertAfterContentItemID')
            request.sendCommandOptionsQueueCompletion(op.command, options, $(), $())
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.15))
          }
        }
        """

    func run<T: Sendable>(_ source: String, parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result: NSAppleEventDescriptor? = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { log.error("script failed: \(String(describing: error), privacy: .public)") }
                continuation.resume(returning: result.flatMap(parse))
            }
        }
    }
}
