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

nonisolated enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// An AirPlay output Music can play to, which isn't necessarily running Tournesol.
nonisolated struct AirPlayDevice: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case computer, appleTV, homePod, airPortExpress, bluetooth, speaker, other
    }

    var name: String
    var kind: Kind
    var isSelected: Bool
    /// What a selection refers to. Outputs can share a name, so the iPhone uses its routes' ids; Music uses names.
    var id: String

    var symbol: String {
        switch kind {
        case .computer: "desktopcomputer"
        case .appleTV: "appletv.fill"
        case .homePod: "homepod.fill"
        case .airPortExpress: "wifi.router.fill"
        case .bluetooth: "hifispeaker.fill"
        case .speaker: "speaker.wave.2.fill"
        case .other: "airplay.audio"
        }
    }

    init(name: String, kind: Kind, isSelected: Bool, id: String? = nil) {
        self.name = name
        self.kind = kind
        self.isSelected = isSelected
        self.id = id ?? name
    }

    init(name: String, kindName: String, isSelected: Bool) {
        let kind: Kind = switch kindName.lowercased() {
        case "computer": .computer
        case "apple tv": .appleTV
        case "homepod": .homePod
        case "airport express": .airPortExpress
        case "bluetooth device": .bluetooth
        default: .other
        }
        self.init(name: name, kind: kind, isSelected: isSelected)
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
    var shuffle: Bool?
    var repeatMode: RepeatMode?
    var isLiked: Bool?
    var airPlay: [AirPlayDevice]?

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
    case loadTrack(TrackReference, at: TimeInterval, upcoming: [TrackReference])
    case enqueue(TrackReference, next: Bool)
    case enqueueAll([TrackReference], next: Bool)
    case setQueue([TrackReference])
    case setShuffle(Bool)
    case setRepeat(RepeatMode)
    case setLiked(Bool)
    case setAirPlay([String])
    case startLoaded(at: TimeInterval)
    case handOff
    case release
}

nonisolated struct JamMember: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: DeviceKind
    /// Whether this device plays the music too, or only takes part as a remote.
    var plays: Bool
    var isGuest: Bool
}

/// What a device hosting a Jam tells everyone nearby, paired or not.
nonisolated struct JamAdvert: Codable, Equatable, Sendable {
    var id: UUID
    var hostName: String
}

/// What a Jam leader tells its members about the session and what's playing.
nonisolated struct JamState: Codable, Equatable, Sendable {
    var id: UUID
    var leaderID: String
    var members: [JamMember]
    var track: TrackReference?
    var isPlaying: Bool
    var position: TimeInterval
    /// The leader's clock when `position` was read.
    var sentAt: Date
    var upcoming: [TrackReference]
    /// How long the leader's sound takes to come out of its speakers, headphones or AirPods.
    var leaderLatency: TimeInterval
}

nonisolated enum JamMessage: Codable, Sendable {
    case invite(JamState)
    case join(UUID, plays: Bool)
    case setPlays(UUID, member: String, plays: Bool)
    case leave(UUID)
    case end(UUID)
    case state(JamState)
    case ping(UInt64, sentAt: Date)
    case pong(UInt64, sentAt: Date, remote: Date)
    /// How far a member's sound is from the leader's, in seconds (positive means ahead).
    case report(UUID, drift: TimeInterval)
    case tune(UUID, TuneStep)
    /// What tuning by ear found: this device's sound comes out that much later than its output says.
    case trim(UUID, by: TimeInterval)
}

/// Tuning by ear asks the other devices to go quiet one at a time, so a single microphone can hear each on its own.
nonisolated enum TuneStep: Codable, Sendable, Equatable {
    case quiet
    case play
    /// Only for the leader: go back so the tuning device can hear the same passage again.
    case rewind(to: TimeInterval)
    case done
}

/// Sent before two devices trust each other, to let someone into a Jam without pairing.
nonisolated enum GuestMessage: Codable, Sendable {
    /// The host asks a nearby device to join.
    case invite(JamAdvert)
    /// A nearby device asks the host to let it in.
    case request(UUID)
    case accept(UUID)
    case decline(UUID)
}

nonisolated struct Hello: Codable, Sendable {
    var info: DeviceInfo
    var publicKey: Data
    var nonce: Data
    var jam: JamAdvert?
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
    case guest(GuestMessage)
}

nonisolated enum Message: Codable, Sendable {
    case state(PlaybackState)
    case artwork(id: String, data: Data)
    case command(Command)
    case requestState
    case unpair
    case controllerFocus(target: String?)
    case pushTokens(PushTokens)
    case requestQueue
    case queue([TrackReference])
    case jam(JamMessage)
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
