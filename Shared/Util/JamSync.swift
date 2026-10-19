//
//  JamSync.swift
//  Tournesol
//
//  How a Jam member stays in step with its leader, kept free of the players so it can be tested.
//

import Foundation

/// Estimates how far another device's clock is ahead of ours from ping/pong round trips.
nonisolated struct ClockOffsetEstimator {
    private var samples: [(offset: TimeInterval, delay: TimeInterval)] = []
    private let capacity = 8

    /// `sent` and `received` are on our clock, `remote` is the other device's when it answered.
    mutating func add(sent: Date, remote: Date, received: Date) {
        let delay = received.timeIntervalSince(sent)
        guard delay >= 0 else { return }
        let midpoint = sent.addingTimeInterval(delay / 2)
        samples.append((remote.timeIntervalSince(midpoint), delay))
        if samples.count > capacity { samples.removeFirst() }
    }

    /// The offset from the quickest round trip, which is the one least bent by network delay.
    var offset: TimeInterval? { samples.min { $0.delay < $1.delay }?.offset }
    var delay: TimeInterval? { samples.map(\.delay).min() }
}

/// Learns how a member's seeks land, so it aims ahead by the right amount and only corrects drift it can actually fix.
nonisolated struct SeekModel {
    private(set) var lead: TimeInterval = 0.25
    private var misses: [TimeInterval] = []

    /// After a seek, how far off playback ended up (positive means ahead).
    mutating func landed(off drift: TimeInterval) {
        guard abs(drift) < 1 else { return }
        lead = min(1, max(0, lead - drift * 0.5))
        misses.append(drift)
        if misses.count > 6 { misses.removeFirst() }
    }

    /// Drift below this isn't worth a seek: a seek wouldn't land any closer. A miss that's always the same is fixed by
    /// the lead, so only how much the misses scatter counts.
    var tolerance: TimeInterval {
        guard misses.count >= 3 else { return 0.035 }
        let mean = misses.reduce(0, +) / Double(misses.count)
        let spread = (misses.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(misses.count)).squareRoot()
        return min(0.12, max(0.02, spread * 2))
    }
}

/// Smooths drift readings, which jump around by tens of milliseconds, so one odd reading doesn't trigger a seek.
nonisolated struct DriftFilter {
    private var readings: [TimeInterval] = []

    mutating func add(_ drift: TimeInterval) -> TimeInterval {
        readings.append(drift)
        if readings.count > 3 { readings.removeFirst() }
        return readings.sorted()[readings.count / 2]
    }

    mutating func reset() { readings = [] }
}

nonisolated enum JamAction: Equatable {
    case none
    case pause
    /// Plays again; `at` is only given when the member is too far off for playing to be enough.
    case resume(at: TimeInterval?)
    case seek(to: TimeInterval)
    case load(TrackReference, at: TimeInterval)
}

nonisolated struct JamPlanner {
    /// The catalog id when both sides have one; otherwise the whole title and the artist, so two versions of a song aren't taken for each other.
    static func isSameTrack(_ local: PlaybackState, _ track: TrackReference) -> Bool {
        if let a = local.catalogID, let b = track.catalogID, !a.isEmpty, !b.isEmpty { return a == b }
        guard let a = local.title, let b = track.title, TrackMatcher.normalize(a) == TrackMatcher.normalize(b) else { return false }
        if let artist = local.artist, let other = track.artist { return TrackMatcher.normalize(artist) == TrackMatcher.normalize(other) }
        return true
    }

    /// Where the leader's player is at `leaderNow`.
    static func expectedPosition(of leader: JamState, at leaderNow: Date) -> TimeInterval {
        let elapsed = leader.isPlaying ? max(0, leaderNow.timeIntervalSince(leader.sentAt)) : 0
        let position = leader.position + elapsed
        guard let duration = leader.track?.duration, duration > 0 else { return position }
        return min(position, duration)
    }

    /// Where this member's player should be so its sound comes out with the leader's. A member whose sound takes longer to
    /// come out (AirPods, a Bluetooth speaker) has to be further along.
    static func target(of leader: JamState, at leaderNow: Date, localLatency: TimeInterval) -> TimeInterval {
        expectedPosition(of: leader, at: leaderNow) + localLatency - leader.leaderLatency
    }

    /// How far this member's sound is from the leader's, or nil when they aren't both playing the same song.
    static func drift(leader: JamState, leaderNow: Date, local: PlaybackState, localNow: Date, localLatency: TimeInterval) -> TimeInterval? {
        guard let track = leader.track, leader.isPlaying, local.isPlaying, isSameTrack(local, track) else { return nil }
        return local.elapsed(at: localNow) - target(of: leader, at: leaderNow, localLatency: localLatency)
    }

    /// What this member should do right now. `drift` is the smoothed reading, `seek` how its seeks land.
    static func action(leader: JamState, leaderNow: Date, local: PlaybackState, localLatency: TimeInterval, drift: TimeInterval?, seek: SeekModel) -> JamAction {
        guard let track = leader.track else { return local.isPlaying ? .pause : .none }
        let target = target(of: leader, at: leaderNow, localLatency: localLatency)
        guard isSameTrack(local, track) else {
            if leader.isPlaying { return .load(track, at: target) }
            return local.isPlaying ? .pause : .none
        }
        guard leader.isPlaying else {
            if local.isPlaying { return .pause }
            return abs(local.elapsed - target) > 1 ? .seek(to: target) : .none
        }
        guard local.isPlaying else { return .resume(at: abs(local.elapsed - target) < 2 ? nil : target + seek.lead) }
        guard let drift, abs(drift) > seek.tolerance else { return .none }
        return .seek(to: target + seek.lead)
    }
}

/// Turns what the microphone heard into how far one device's sound is from the tuning device's.
nonisolated enum JamTuning {
    /// `lag` is where the other device's take starts inside this device's take; `positions` are the leader's song
    /// positions when each take began, and `drifts` what each device reported then. Positive means the other device
    /// sounds ahead of this one.
    static func offset(lag: TimeInterval, positions: (other: TimeInterval, local: TimeInterval), drifts: (other: TimeInterval, local: TimeInterval)) -> TimeInterval {
        lag - (positions.other - positions.local) - drifts.other + drifts.local
    }
}
