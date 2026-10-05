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
        function snapshot() {
          const result = { client: '' }
          try {
            result.client = ObjC.unwrap(Request.localNowPlayingPlayerPath.client.bundleIdentifier) || ''
            const info = Request.localNowPlayingItem.nowPlayingInfo
            if (info.isNil()) return result
            const get = (k) => { const v = info.objectForKey(prefix + k); return v.isNil() ? null : ObjC.deepUnwrap(v) }
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
        while (true) {
          const snap = snapshot()
          const art = snap._art
          delete snap._art
          const artKey = (snap.title || '') + '|' + (snap.artworkLength || 0)
          const line = JSON.stringify(snap)
          if (line !== last || (art && artKey !== lastArt)) {
            if (art && artKey !== lastArt) { snap.artwork = ObjC.unwrap(art.base64EncodedStringWithOptions(0)); lastArt = artKey }
            stdout.writeData($(JSON.stringify(snap) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding))
            last = line
          }
          delay(0.25)
        }
        """
}

nonisolated final class MusicScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ch.cclerc.Tournesol.music-script", qos: .userInitiated)

    func send(_ command: String) {
        queue.async {
            _ = NSAppleScript(source: "tell application \"Music\" to \(command)")?.executeAndReturnError(nil)
        }
    }

    func run<T: Sendable>(_ source: String, parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result: NSAppleEventDescriptor? = NSAppleScript(source: source)?.executeAndReturnError(nil)
                continuation.resume(returning: result.flatMap(parse))
            }
        }
    }
}
