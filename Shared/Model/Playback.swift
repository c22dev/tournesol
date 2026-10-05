//
//  Playback.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import Foundation

nonisolated enum DeviceKind: String, Codable, Sendable {
    case iPhone, iPad, macBook, mac

    var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .macBook: "laptopcomputer"
        case .mac: "desktopcomputer"
        }
    }

    var displayName: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .macBook, .mac: "Mac"
        }
    }
}

nonisolated struct DeviceInfo: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: DeviceKind
}

nonisolated struct AudioOutput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtIn, headphones, airPods, airPodsPro, airPodsMax, bluetooth, airPlay, display, car
    }

    var name: String
    var kind: Kind

    var symbol: String {
        switch kind {
        case .builtIn: "speaker.wave.2.fill"
        case .headphones: "headphones"
        case .airPods: "airpods"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .bluetooth: "hifispeaker.fill"
        case .airPlay: "airplay.audio"
        case .display: "tv"
        case .car: "car.fill"
        }
    }

    static func kind(forName name: String, fallback: Kind) -> Kind {
        let name = name.lowercased()
        if name.contains("airpods max") { return .airPodsMax }
        if name.contains("airpods pro") { return .airPodsPro }
        if name.contains("airpods") { return .airPods }
        if name.contains("beats") || name.contains("headphone") { return .headphones }
        return fallback
    }
}

nonisolated struct PlaybackState: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var timestamp = Date.now
    var isPlaying = false
    var volume: Double?
    var output: AudioOutput?
    var artworkID: String?
    var catalogID: String?
    var loadedSignature: String?

    static let idle = PlaybackState()

    var track: TrackReference {
        TrackReference(catalogID: catalogID, title: title, artist: artist, album: album, duration: duration)
    }

    var hasTrack: Bool { title != nil }

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        return min(duration, max(0, elapsed + date.timeIntervalSince(timestamp)))
    }

    func differs(from other: PlaybackState) -> Bool {
        let drift = abs(elapsed(at: .now) - other.elapsed(at: .now))
        var lhs = self, rhs = other
        (lhs.elapsed, lhs.timestamp, rhs.elapsed, rhs.timestamp) = (0, .distantPast, 0, .distantPast)
        return lhs != rhs || drift > 1.5
    }
}

nonisolated struct Artwork: Equatable, Sendable {
    let id: String
    let data: Data
}

nonisolated struct TrackReference: Codable, Equatable, Sendable {
    var catalogID: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval

    var signature: String {
        [title, artist, album].map { $0 ?? "" }.joined(separator: "|")
    }
}

nonisolated enum Command: Codable, Sendable {
    case play, pause, togglePlayPause, next, previous
    case seek(TimeInterval)
    case setVolume(Double)
    case loadTrack(TrackReference, at: TimeInterval)
    case startLoaded(at: TimeInterval)
    case handOff
    case release
}

nonisolated struct Hello: Codable, Sendable {
    var info: DeviceInfo
    var publicKey: Data
    var nonce: Data
}

nonisolated enum PairingMessage: Codable, Sendable {
    case request
    case commit(Data)
    case nonce(Data)
    case confirm(Bool)
}

nonisolated enum Envelope: Codable, Sendable {
    case hello(Hello)
    case pairing(PairingMessage)
    case sealed(sequence: UInt64, box: Data)
}

nonisolated enum Message: Codable, Sendable {
    case state(PlaybackState)
    case artwork(id: String, data: Data)
    case command(Command)
    case requestState
    case unpair
    case controllerFocus(target: String?)
    case pushTokens(PushTokens)
}

nonisolated struct PushTokens: Codable, Equatable, Sendable {
    var environment: String
    var startToken: String?
    var activityTokens: [String: String] = [:]
}

nonisolated enum MessageCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}

enum DeviceIdentity {
    static var id: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }
}
