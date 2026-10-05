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

final class SilentAudio {
    static private(set) var isRunning = false

    private var player: AVAudioPlayer?
    private var keepAirPodsFree: Bool?

    func start(keepAirPodsFree: Bool) {
        if Self.isRunning, self.keepAirPodsFree == keepAirPodsFree, player?.isPlaying == true { return }
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
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence)
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        player?.play()
        self.keepAirPodsFree = keepAirPodsFree
        Self.isRunning = true
        log.debug("silent audio on (keep AirPods free: \(keepAirPodsFree))")
    }

    func stop() {
        guard Self.isRunning else { return }
        player?.stop()
        Self.isRunning = false
        keepAirPodsFree = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: .mixWithOthers)
        if UIApplication.shared.applicationState == .background {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        log.debug("silent audio off")
    }

    private static let silence: Data = {
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
