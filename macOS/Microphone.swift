//
//  Microphone.swift
//  TournesolMac
//
//  Records the room while a Jam is tuned by ear, remembering when each sample was heard.
//

import AVFoundation

nonisolated final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var startedAt: Date?
    private var rate: Double = 0

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    struct NoInput: Error {}

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // a Mac without a microphone reports a 0 Hz format, which installTap answers by raising an exception
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInput() }
        rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.append(buffer, at: time)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock {
            if startedAt == nil, time.isHostTimeValid {
                let age = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: time.hostTime)
                startedAt = Date.now.addingTimeInterval(-age)
            }
            samples.append(contentsOf: chunk)
        }
    }

    /// What was heard between two moments, averaged down to about 16 kHz, which is plenty to line music up.
    func clip(from start: Date, to end: Date) -> (samples: [Float], rate: Double)? {
        lock.withLock {
            guard let startedAt, rate > 0 else { return nil }
            let first = Int(start.timeIntervalSince(startedAt) * rate)
            let last = min(samples.count, Int(end.timeIntervalSince(startedAt) * rate))
            guard first >= 0, last - first > Int(rate) else { return nil }
            let factor = max(1, Int(rate / 16_000))
            let reduced = stride(from: first, to: last - factor + 1, by: factor).map { index in
                samples[index..<(index + factor)].reduce(0, +) / Float(factor)
            }
            return (reduced, rate / Double(factor))
        }
    }
}
