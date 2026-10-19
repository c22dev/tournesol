//
//  Jam.swift
//  Tournesol
//
//  A Jam is a leader and its members. The leader owns the queue and playback; every member can add songs,
//  and any member can also play the music, kept in step with the leader.
//

import Foundation
import Observation
import OSLog

nonisolated private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "Jam")

@Observable
final class JamSession {
    let id: UUID
    let leaderID: String
    let localID: String
    var members: [JamMember]
    /// How far each member's sound is from the leader's, as the members report it.
    var drifts: [String: TimeInterval] = [:]

    init(id: UUID, leaderID: String, localID: String, members: [JamMember]) {
        self.id = id
        self.leaderID = leaderID
        self.localID = localID
        self.members = members
    }

    var isLeader: Bool { leaderID == localID }
    var playsHere: Bool { isLeader || members.first { $0.id == localID }?.plays == true }
    var leaderName: String { members.first { $0.id == leaderID }?.name ?? "Jam" }
}

/// What tuning by ear learned about each output, on top of the latency the system reports for it.
enum LatencyTrim {
    private static let key = "jamLatencyTrim"

    static var current: TimeInterval {
        UserDefaults.standard.dictionary(forKey: key)?[OutputLatency.route] as? Double ?? 0
    }

    static func adjust(by delta: TimeInterval) {
        var trims = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        trims[OutputLatency.route] = min(1, max(-1, current + delta))
        UserDefaults.standard.set(trims, forKey: key)
    }
}

/// What the Jam needs from the hub: reaching other devices and letting guests in or out.
struct JamLinks {
    /// False when the device couldn't be reached.
    var send: (JamMessage, String) -> Bool
    var advertise: (JamAdvert?) -> Void
    var inviteGuest: (RemoteDevice) -> Void
    var askToJoin: (RemoteDevice, Bool) -> Void
    var dismissGuest: (String) -> Void
}

final class JamCoordinator {
    static let autoJoinKey = "jamAutoJoin"

    private let local: RemoteDevice
    private let player: LocalPlayer
    private let store: DeviceStore
    private let links: JamLinks

    private var clock = ClockOffsetEstimator()
    private var seek = SeekModel()
    private var filter = DriftFilter()
    private var leaderState: JamState?
    private var leaderHeardAt = ContinuousClock.now
    private var lastBroadcast: JamState?
    private var lastBroadcastAt = ContinuousClock.now
    private var upcoming: [TrackReference] = []
    private var upcomingFetchedAt = ContinuousClock.now - .seconds(60)
    private var latency: TimeInterval = 0
    private var loop: Task<Void, Never>?
    private var cooldownUntil = ContinuousClock.now
    private var awaitingLanding = false
    private var lastReport = ContinuousClock.now
    private var lastPing = ContinuousClock.now - .seconds(60)
    private var pingCount: UInt64 = 0
    /// Jams this device asked to join, or agreed to, with whether it wants to play.
    private var expected: [UUID: Bool] = [:]
    /// Your devices already invited to this Jam, so one that leaves isn't pulled back in.
    private var invited: Set<String> = []
    /// While another device tunes the Jam by ear, this one keeps still and goes quiet when asked.
    private var holdUntil: ContinuousClock.Instant?
    private var volumeBeforeTuning: Double?

    init(local: RemoteDevice, player: LocalPlayer, store: DeviceStore, links: JamLinks) {
        self.local = local
        self.player = player
        self.store = store
        self.links = links
        UserDefaults.standard.register(defaults: [Self.autoJoinKey: true])
    }

    private var session: JamSession? { store.jam }
    private var localID: String { local.id }

    // MARK: Starting, joining, leaving

    /// Starts a Jam led by this device. Your other connected devices join as remotes; you pick which ones play.
    func start() {
        guard session == nil else { return }
        let me = JamMember(id: localID, name: local.info.name, kind: local.info.kind, plays: true, isGuest: false)
        let session = JamSession(id: UUID(), leaderID: localID, localID: localID, members: [me])
        store.jam = session
        links.advertise(JamAdvert(id: session.id, hostName: local.info.name))
        invited = []
        for device in store.remotes where device.isConnected { inviteOwn(device) }
        log.info("started a jam")
        startLoop()
    }

    /// A device's secure link just came up. One of yours that hasn't been asked yet gets invited.
    func deviceConnected(_ device: RemoteDevice) {
        guard session?.isLeader == true, device.access == .full, device.isPaired else { return }
        inviteOwn(device)
    }

    private func inviteOwn(_ device: RemoteDevice) {
        guard let session, !invited.contains(device.id), !session.members.contains(where: { $0.id == device.id }) else { return }
        if links.send(.invite(snapshot(for: session)), device.id) { invited.insert(device.id) }
    }

    func invite(_ device: RemoteDevice) {
        guard let session, session.isLeader else { return }
        // Paired devices and guests already let in get the Jam; anyone else is first asked to come in as a guest.
        if device.isPaired {
            _ = links.send(.invite(snapshot(for: session)), device.id)
        } else {
            links.inviteGuest(device)
        }
    }

    /// Joins the Jam a nearby device is hosting.
    func join(_ host: RemoteDevice, playsHere: Bool) {
        guard session == nil, let advert = host.jamAdvert else { return }
        expected[advert.id] = playsHere
        if host.access == .full, host.isPaired {
            _ = links.send(.join(advert.id, plays: playsHere), host.id)
        } else {
            links.askToJoin(host, playsHere)
        }
    }

    /// A guest handshake finished: the invitation that follows is the one we agreed to.
    func expectInvite(to id: UUID, playsHere: Bool) {
        expected[id] = playsHere
    }

    func setPlays(_ memberID: String, _ plays: Bool) {
        guard let session else { return }
        if session.isLeader {
            guard memberID != localID, let index = session.members.firstIndex(where: { $0.id == memberID }) else { return }
            session.members[index].plays = plays
            broadcast(force: true)
        } else if memberID == localID {
            if let index = session.members.firstIndex(where: { $0.id == localID }) { session.members[index].plays = plays }
            _ = links.send(.setPlays(session.id, member: localID, plays: plays), session.leaderID)
            if !plays { player.perform(.pause) }
        }
    }

    func playOnAll(_ plays: Bool) {
        guard let session, session.isLeader else { return }
        for index in session.members.indices where session.members[index].id != localID {
            session.members[index].plays = plays
        }
        broadcast(force: true)
    }

    func leave() {
        guard let session else { return }
        if session.isLeader {
            for member in session.members where member.id != localID { _ = links.send(.end(session.id), member.id) }
        } else {
            _ = links.send(.leave(session.id), session.leaderID)
        }
        finish()
    }

    private func finish() {
        guard let session else { return }
        loop?.cancel()
        loop = nil
        if session.isLeader {
            links.advertise(nil)
            for member in session.members where member.isGuest { links.dismissGuest(member.id) }
        } else if store.device(id: session.leaderID)?.access == .guestHost {
            links.dismissGuest(session.leaderID)
        }
        if volumeBeforeTuning != nil { tuning(.done) }
        store.jam = nil
        leaderState = nil
        lastBroadcast = nil
        filter.reset()
        log.info("jam ended")
    }

    // MARK: Messages

    func receive(_ message: JamMessage, from deviceID: String) {
        switch message {
        case .invite(let state):
            guard session == nil else { return }
            if let plays = expected.removeValue(forKey: state.id) {
                accept(state, playsHere: plays)
            } else if UserDefaults.standard.bool(forKey: Self.autoJoinKey), store.device(id: deviceID)?.access == .full {
                accept(state, playsHere: false)
            } else if let host = store.device(id: deviceID) {
                let prompt = JamPrompt(kind: .invite, deviceName: host.info.name, deviceSymbol: host.info.kind.symbol, isGuest: host.access != .full)
                prompt.respond = { [weak self] accepted, plays in
                    self?.store.jamPrompt = nil
                    if accepted { self?.accept(state, playsHere: plays) }
                }
                store.jamPrompt = prompt
            }
        case .join(let id, let plays):
            guard let session, session.isLeader, session.id == id, let device = store.device(id: deviceID) else { return }
            if let index = session.members.firstIndex(where: { $0.id == deviceID }) {
                session.members[index].plays = plays
            } else {
                session.members.append(JamMember(id: deviceID, name: device.info.name, kind: device.info.kind, plays: plays, isGuest: device.access == .guestMember))
            }
            broadcast(force: true)
        case .setPlays(let id, let member, let plays):
            guard let session, session.isLeader, session.id == id, member == deviceID,
                  let index = session.members.firstIndex(where: { $0.id == member }) else { return }
            session.members[index].plays = plays
            broadcast(force: true)
        case .leave(let id):
            guard let session, session.isLeader, session.id == id else { return }
            removeMember(deviceID)
        case .end(let id):
            guard let session, session.id == id, session.leaderID == deviceID else { return }
            finish()
        case .state(let state):
            guard let session, session.id == state.id, session.leaderID == deviceID else { return }
            let wasPlaying = session.playsHere
            leaderState = state
            leaderHeardAt = .now
            session.members = state.members
            if wasPlaying, !session.playsHere { player.perform(.pause) }
            followStep()
        case .ping(let id, let sentAt):
            _ = links.send(.pong(id, sentAt: sentAt, remote: .now), deviceID)
        case .pong(_, let sentAt, let remote):
            clock.add(sent: sentAt, remote: remote, received: .now)
        case .report(let id, let drift):
            guard let session, session.isLeader, session.id == id else { return }
            session.drifts[deviceID] = drift
        case .tune(let id, let step):
            guard let session, session.id == id, session.members.contains(where: { $0.id == deviceID }) else { return }
            tuning(step)
        case .trim(let id, let delta):
            guard let session, session.id == id, session.leaderID == deviceID else { return }
            LatencyTrim.adjust(by: delta)
            log.info("tuned by ear: \(Int(delta * 1000)) ms")
        }
    }

    private func tuning(_ step: TuneStep) {
        switch step {
        case .quiet:
            holdUntil = .now + .seconds(40)
            if volumeBeforeTuning == nil { volumeBeforeTuning = local.state.volume }
            local.setVolume(0)
        case .play:
            holdUntil = .now + .seconds(40)
            if let volume = volumeBeforeTuning { local.setVolume(volume) }
        case .rewind(let position):
            if session?.isLeader == true { player.perform(.seek(max(0, position))) }
        case .done:
            holdUntil = nil
            if let volume = volumeBeforeTuning { local.setVolume(volume) }
            volumeBeforeTuning = nil
        }
    }

    private func accept(_ state: JamState, playsHere: Bool) {
        let session = JamSession(id: state.id, leaderID: state.leaderID, localID: localID, members: state.members)
        store.jam = session
        leaderState = state
        leaderHeardAt = .now
        clock = ClockOffsetEstimator()
        seek = SeekModel()
        filter.reset()
        store.autoSelect(state.leaderID)
        _ = links.send(.join(state.id, plays: playsHere), state.leaderID)
        log.info("joined a jam, playing here: \(playsHere)")
        startLoop()
    }

    private func removeMember(_ id: String) {
        guard let session else { return }
        let wasGuest = session.members.first { $0.id == id }?.isGuest == true
        session.members.removeAll { $0.id == id }
        session.drifts[id] = nil
        if wasGuest { links.dismissGuest(id) }
        broadcast(force: true)
    }

    func deviceDisconnected(_ id: String) {
        guard let session else { return }
        if session.isLeader {
            if session.members.contains(where: { $0.id == id }) { removeMember(id) }
        } else if session.leaderID == id {
            finish()
        }
    }

    /// The leader announces a change as soon as its own playback changes.
    func localDidChange() {
        guard session?.isLeader == true else { return }
        broadcast(force: false)
    }

    // MARK: Loop

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard let session else { return }
        latency = OutputLatency.current + LatencyTrim.current
        if let holdUntil, ContinuousClock.now > holdUntil { tuning(.done) }
        if session.isLeader {
            if ContinuousClock.now - upcomingFetchedAt > .seconds(3) {
                upcomingFetchedAt = .now
                upcoming = Array(await player.upcomingTracks().prefix(10))
            }
            broadcast(force: ContinuousClock.now - lastBroadcastAt > .seconds(2))
        } else {
            if ContinuousClock.now - leaderHeardAt > .seconds(20) { return finish() }
            if ContinuousClock.now - lastPing > .seconds(clock.offset == nil ? 1 : 4) {
                lastPing = .now
                pingCount += 1
                _ = links.send(.ping(pingCount, sentAt: .now), session.leaderID)
            }
            followStep()
        }
    }

    // MARK: Leader

    private func snapshot(for session: JamSession) -> JamState {
        let now = Date.now
        let state = player.state
        return JamState(
            id: session.id, leaderID: localID, members: session.members,
            track: state.hasTrack ? state.track : nil, isPlaying: state.isPlaying,
            position: state.elapsed(at: now), sentAt: now, upcoming: upcoming, leaderLatency: latency
        )
    }

    private func broadcast(force: Bool) {
        guard let session, session.isLeader else { return }
        let state = snapshot(for: session)
        if !force, let last = lastBroadcast, !Self.changed(from: last, to: state) { return }
        lastBroadcast = state
        lastBroadcastAt = .now
        for member in session.members where member.id != localID { _ = links.send(.state(state), member.id) }
    }

    /// Whether members need to hear about it now, rather than at the next heartbeat.
    private static func changed(from old: JamState, to new: JamState) -> Bool {
        if old.isPlaying != new.isPlaying || old.members != new.members || old.track?.signature != new.track?.signature { return true }
        // A seek shows as the position leaving the line the last report set out.
        let expected = old.isPlaying ? old.position + new.sentAt.timeIntervalSince(old.sentAt) : old.position
        return abs(new.position - expected) > 0.5
    }

    // MARK: Tuning by ear

    #if os(macOS)
    /// Listens to each device on its own and corrects for the delay its output adds that the system didn't report:
    /// first the others one at a time while this Mac is quiet, then this Mac alone over the same part of the song.
    /// Returns what it found, for the person to read.
    func tuneByEar() async -> String {
        guard let session, session.playsHere else { return "Turn on Play Here on this Mac first." }
        guard player.state.isPlaying, leaderPosition(at: .now) != nil else { return "Start the music first." }
        let others = session.members.filter { member in
            member.id != localID && member.plays && (session.isLeader || member.id == session.leaderID)
        }
        guard !others.isEmpty else { return "No other device is playing." }
        guard local.state.volume != nil else { return "Can't change this Mac's volume." }
        guard await Microphone.requestAccess() else { return "Tournesol needs the microphone to tune by ear. Allow it in System Settings › Privacy & Security." }

        let microphone = Microphone()
        do { try microphone.start() } catch { return "Couldn't use the microphone." }
        defer { microphone.stop() }

        func tell(_ step: TuneStep, _ ids: [String]) { for id in ids { _ = links.send(.tune(session.id, step), id) } }
        let ids = others.map(\.id)
        let myVolume = local.state.volume ?? 0.5
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

        // Everyone else alone, one at a time.
        tell(.quiet, ids)
        local.setVolume(0)
        await wait(1)
        var takes: [(member: JamMember, start: Date, end: Date, position: TimeInterval, drift: TimeInterval)] = []
        for member in others {
            tell(.play, [member.id])
            await wait(0.8)
            let start = Date.now
            guard let position = leaderPosition(at: start) else { break }
            await wait(4)
            let drift = member.id == session.leaderID ? 0 : session.drifts[member.id] ?? 0
            takes.append((member, start, .now, position, drift))
            tell(.quiet, [member.id])
        }

        // This Mac alone, back over the same passage. A member has to catch up with the leader's jump first.
        let settle = session.isLeader ? 1.5 : 5.0
        let rewindTo = (takes.first?.position ?? 0) - settle - 1
        if session.isLeader {
            player.perform(.seek(max(0, rewindTo)))
        } else {
            tell(.rewind(to: rewindTo), [session.leaderID])
        }
        local.setVolume(myVolume)
        await wait(settle)
        holdUntil = .now + .seconds(30)
        let start = Date.now
        let myDrift = session.isLeader ? 0 : session.drifts[localID] ?? 0
        let position = leaderPosition(at: start)
        if let position, let last = takes.last { await wait(max(1, last.position + 5 - position)) }
        let end = Date.now
        holdUntil = nil
        tell(.done, ids)

        guard let position, let mine = microphone.clip(from: start, to: end) else { return "Couldn't hear this Mac. Turn the volume up and try again." }
        var found: [String] = []
        for take in takes {
            let expected = take.position - position
            guard let theirs = microphone.clip(from: take.start, to: take.end),
                  let match = AudioAlignment.match(theirs.samples, in: mine.samples, sampleRate: mine.rate, minLag: expected - 0.6, maxLag: expected + 0.6),
                  match.confidence >= 8 else {
                found.append("Couldn't hear \(take.member.name) clearly. Bring it closer to this Mac or turn it up.")
                continue
            }
            let offset = JamTuning.offset(lag: match.lag, positions: (take.position, position), drifts: (take.drift, myDrift))
            log.info("tuning \(take.member.name, privacy: .public): \(Int(offset * 1000)) ms, confidence \(Int(match.confidence))")
            let milliseconds = Int((abs(offset) * 1000).rounded())
            if session.isLeader {
                _ = links.send(.trim(session.id, by: -offset), take.member.id)
            } else {
                LatencyTrim.adjust(by: offset)
            }
            found.append(milliseconds < 5
                ? "\(take.member.name) was already in step."
                : "\(take.member.name) was \(milliseconds) ms \(offset > 0 ? "ahead" : "behind"). Fixed.")
        }
        return found.joined(separator: "\n")
    }

    /// Where the leader's song is at a moment on this device's clock.
    private func leaderPosition(at date: Date) -> TimeInterval? {
        guard let session else { return nil }
        if session.isLeader { return player.state.elapsed(at: date) }
        guard let leaderState, let offset = clock.offset else { return nil }
        return JamPlanner.expectedPosition(of: leaderState, at: date.addingTimeInterval(offset))
    }
    #endif

    // MARK: Member

    private func followStep() {
        guard let session, !session.isLeader, session.playsHere, let leader = leaderState, let offset = clock.offset else { return }
        let local = player.state
        let now = Date.now
        let leaderNow = now.addingTimeInterval(offset)

        let reading = JamPlanner.drift(leader: leader, leaderNow: leaderNow, local: local, localNow: now, localLatency: latency)
        let drift = reading.map { filter.add($0) }
        if reading == nil { filter.reset() }
        if let drift { session.drifts[localID] = drift }
        if let drift, ContinuousClock.now - lastReport > .seconds(2) {
            lastReport = .now
            _ = links.send(.report(session.id, drift: drift), session.leaderID)
        }

        guard ContinuousClock.now >= cooldownUntil, holdUntil == nil else { return }
        if awaitingLanding, let reading {
            awaitingLanding = false
            seek.landed(off: reading)
        }

        let action = JamPlanner.action(leader: leader, leaderNow: leaderNow, local: local, localLatency: latency, drift: drift, seek: seek)
        perform(action, leader: leader)
    }

    private func perform(_ action: JamAction, leader: JamState) {
        switch action {
        case .none:
            return
        case .pause:
            player.perform(.pause)
            cooldownUntil = .now + .seconds(1)
        case .resume(let position):
            if let position { player.perform(.seek(position)) }
            player.perform(.play)
            filter.reset()
            awaitingLanding = position != nil
            cooldownUntil = .now + .seconds(position == nil ? 2 : 3)
        case .seek(let position):
            player.perform(.seek(position))
            filter.reset()
            awaitingLanding = true
            cooldownUntil = .now + .seconds(2.5)
        case .load(let track, let position):
            log.info("loading \(track.title ?? "?", privacy: .public)")
            player.perform(.loadTrack(track, at: position, upcoming: leader.upcoming))
            player.perform(.startLoaded(at: position))
            filter.reset()
            cooldownUntil = .now + .seconds(4)
        }
    }
}
