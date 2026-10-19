//
//  SilentAudio.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AVFoundation
import OSLog
import UIKit

nonisolated private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "NowPlaying")

nonisolated final class AudioSessionQueue: @unchecked Sendable {
    static let shared = AudioSessionQueue()
    private let queue = DispatchQueue(label: "ch.cclerc.Tournesol.audio-session", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var routeObserver: NSObjectProtocol?

    /// Posted on the main queue before and after the session's category or activation changes, so volume readings around it can be told apart from button presses.
    static let willChange = Notification.Name("AudioSessionQueue.willChange")
    static let didChange = Notification.Name("AudioSessionQueue.didChange")

    /// Runs a session change on the queue, announcing it first so no reading made during it is taken for a button.
    private func change(_ work: @escaping () -> Void) {
        let announce = { (name: Notification.Name) in
            if Thread.isMainThread { NotificationCenter.default.post(name: name, object: nil) }
            else { DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil) } }
        }
        announce(Self.willChange)
        queue.async {
            work()
            announce(Self.didChange)
        }
    }

    func setActive(_ active: Bool) {
        change {
            let session = AVAudioSession.sharedInstance()
            if active {
                try? session.setActive(true)
            } else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    func useAmbient(activate: Bool) {
        change {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, options: .mixWithOthers)
            if activate { try? session.setActive(true) }
        }
    }

    func startSilence(keepAirPodsFree: Bool, data: Data) {
        change { [self] in
            let session = AVAudioSession.sharedInstance()
            do {
                if keepAirPodsFree {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                } else {
                    try session.setCategory(.playback, mode: .default)
                }
                try session.setActive(true)
            } catch {
                log.error("audio session failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if keepAirPodsFree { keepOnSpeaker() }
            watchRoute(keepOnSpeaker: keepAirPodsFree)
            if player == nil {
                player = try? AVAudioPlayer(data: data)
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            player?.play()
            log.debug("silent audio on (keep AirPods free: \(keepAirPodsFree))")
        }
    }

    func pauseSilence() {
        queue.async { [self] in
            player?.pause()
            log.debug("silent audio paused")
        }
    }

    /// Silence reaching AirPods pulls them off whatever else they're playing.
    private func keepOnSpeaker() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { $0.portType != .builtInSpeaker }) {
            try? session.overrideOutputAudioPort(.speaker)
            log.debug("moved silence to the speaker from \(outputs.map(\.portType.rawValue).joined(separator: ", "), privacy: .public)")
        }
    }

    private func watchRoute(keepOnSpeaker keep: Bool) {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        guard keep else { return }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.keepOnSpeaker() }
        }
    }

    func stopSilence(deactivate: Bool) {
        change { [self] in
            watchRoute(keepOnSpeaker: false)
            player?.stop()
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, options: .mixWithOthers)
            if deactivate { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            log.debug("silent audio off")
        }
    }
}

final class SilentAudio {
    static private(set) var isRunning = false
    private var keepAirPodsFree: Bool?
    private var isPlaying = false

    @discardableResult
    func start(keepAirPodsFree: Bool) -> Bool {
        if Self.isRunning, isPlaying, self.keepAirPodsFree == keepAirPodsFree { return false }
        self.keepAirPodsFree = keepAirPodsFree
        Self.isRunning = true
        isPlaying = true
        AudioSessionQueue.shared.startSilence(keepAirPodsFree: keepAirPodsFree, data: Self.silence)
        return true
    }

    func pause() {
        guard Self.isRunning, isPlaying else { return }
        isPlaying = false
        AudioSessionQueue.shared.pauseSilence()
    }

    func stop() {
        guard Self.isRunning else { return }
        Self.isRunning = false
        isPlaying = false
        keepAirPodsFree = nil
        AudioSessionQueue.shared.stopSilence(deactivate: UIApplication.shared.applicationState == .background)
    }

    nonisolated private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let samples = Data(count: Int(sampleRate))
        var wav = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count).littleEndian)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(sampleRate.littleEndian); append(sampleRate.littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(8).littleEndian)
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count).littleEndian)
        wav.append(Data(repeating: 128, count: samples.count))
        return wav
    }()
}
