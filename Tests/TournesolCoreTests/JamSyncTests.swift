import Foundation
import Testing
@testable import TournesolCore

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func track(_ title: String, duration: TimeInterval = 200) -> TrackReference {
    TrackReference(catalogID: "1", title: title, artist: "A", album: "B", duration: duration)
}

private func leader(_ title: String? = "Song", position: TimeInterval = 50, playing: Bool = true, latency: TimeInterval = 0) -> JamState {
    let members = [JamMember(id: "L", name: "Leader", kind: .mac, plays: true, isGuest: false), JamMember(id: "M", name: "Member", kind: .iPhone, plays: true, isGuest: false)]
    return JamState(id: UUID(), leaderID: "L", members: members, track: title.map { track($0) }, isPlaying: playing, position: position, sentAt: epoch, upcoming: [], leaderLatency: latency)
}

private func local(_ title: String? = "Song", elapsed: TimeInterval, playing: Bool = true, at date: Date = epoch) -> PlaybackState {
    var state = PlaybackState()
    state.title = title
    state.artist = "A"
    state.duration = 200
    state.elapsed = elapsed
    state.timestamp = date
    state.isPlaying = playing
    return state
}

@Suite struct ClockOffsetTests {
    @Test func aClockAheadByTwoSecondsIsMeasured() {
        var estimator = ClockOffsetEstimator()
        estimator.add(sent: epoch, remote: epoch.addingTimeInterval(2.05), received: epoch.addingTimeInterval(0.1))
        #expect(abs((estimator.offset ?? 0) - 2) < 0.0001)
        #expect(abs((estimator.delay ?? 0) - 0.1) < 0.0001)
    }

    @Test func theQuickestRoundTripWins() {
        var estimator = ClockOffsetEstimator()
        estimator.add(sent: epoch, remote: epoch.addingTimeInterval(1.5), received: epoch.addingTimeInterval(1.0))
        estimator.add(sent: epoch, remote: epoch.addingTimeInterval(0.51), received: epoch.addingTimeInterval(0.02))
        #expect(abs((estimator.offset ?? 0) - 0.5) < 0.0001)
    }

    @Test func aReplyFromThePastIsIgnored() {
        var estimator = ClockOffsetEstimator()
        estimator.add(sent: epoch, remote: epoch, received: epoch.addingTimeInterval(-1))
        #expect(estimator.offset == nil)
    }
}

@Suite struct SeekModelTests {
    @Test func landingLateMeansAimingFurtherAhead() {
        var model = SeekModel()
        model.landed(off: -0.2)
        #expect(abs(model.lead - 0.35) < 0.0001)
        model.landed(off: 0.1)
        #expect(abs(model.lead - 0.30) < 0.0001)
    }

    @Test func toleranceFollowsHowMuchSeeksScatter() {
        var precise = SeekModel()
        for miss in [0.02, -0.03, 0.02] { precise.landed(off: miss) }
        #expect(abs(precise.tolerance - 0.0471) < 0.001)
        var sloppy = SeekModel()
        for miss in [0.12, -0.15, 0.1] { sloppy.landed(off: miss) }
        #expect(sloppy.tolerance == 0.12)
    }

    @Test func aConsistentMissKeepsTheToleranceTight() {
        // Always landing 0.19 s early is a lead problem, which the lead fixes; it shouldn't stop corrections.
        var model = SeekModel()
        for miss in [0.19, 0.18, 0.2] { model.landed(off: miss) }
        #expect(model.tolerance == 0.02)
    }

    @Test func outliersDoNotTeachAnything() {
        var model = SeekModel()
        model.landed(off: 3)
        #expect(model.lead == 0.25)
        #expect(model.tolerance == 0.035)
    }
}

@Suite struct DriftFilterTests {
    @Test func oneOddReadingIsIgnored() {
        var filter = DriftFilter()
        _ = filter.add(0.01)
        _ = filter.add(0.02)
        #expect(filter.add(0.4) == 0.02)
    }
}

@Suite struct JamPlannerTests {
    private let seek = SeekModel()

    @Test func theExpectedPositionAdvancesWhilePlayingAndHoldsWhenPaused() {
        let later = epoch.addingTimeInterval(10)
        #expect(JamPlanner.expectedPosition(of: leader(position: 50), at: later) == 60)
        #expect(JamPlanner.expectedPosition(of: leader(position: 50, playing: false), at: later) == 50)
        #expect(JamPlanner.expectedPosition(of: leader(position: 195), at: epoch.addingTimeInterval(30)) == 200)
    }

    @Test func slowerSpeakersAreAimedFurtherAlong() {
        // Leader on its own speakers (20 ms), member on AirPods (220 ms): the member's player must be 200 ms ahead.
        let target = JamPlanner.target(of: leader(position: 50, latency: 0.02), at: epoch, localLatency: 0.22)
        #expect(abs(target - 50.2) < 0.0001)
    }

    @Test func driftIsMeasuredInWhatYouHear() {
        let drift = JamPlanner.drift(leader: leader(position: 50, latency: 0.02), leaderNow: epoch, local: local(elapsed: 50.2), localNow: epoch, localLatency: 0.22)
        #expect(abs((drift ?? 1) - 0) < 0.0001)
    }

    @Test func smallDriftIsLeftAlone() {
        let action = JamPlanner.action(leader: leader(), leaderNow: epoch, local: local(elapsed: 50.02), localLatency: 0, drift: 0.02, seek: seek)
        #expect(action == .none)
    }

    @Test func driftBeyondToleranceSeeksPastTheSeekDelay() {
        let action = JamPlanner.action(leader: leader(), leaderNow: epoch.addingTimeInterval(5), local: local(elapsed: 54), localLatency: 0, drift: -1, seek: seek)
        #expect(action == .seek(to: 55.25))
    }

    @Test func aDifferentSongIsLoadedWhereTheLeaderIs() {
        let action = JamPlanner.action(leader: leader("Song", position: 50), leaderNow: epoch, local: local("Other", elapsed: 10), localLatency: 0, drift: nil, seek: seek)
        #expect(action == .load(track("Song"), at: 50))
    }

    @Test func aPausedLeaderPausesAMemberEvenOnAnotherSong() {
        #expect(JamPlanner.action(leader: leader(playing: false), leaderNow: epoch, local: local("Other", elapsed: 10), localLatency: 0, drift: nil, seek: seek) == .pause)
        #expect(JamPlanner.action(leader: leader(playing: false), leaderNow: epoch, local: local(elapsed: 50), localLatency: 0, drift: nil, seek: seek) == .pause)
        #expect(JamPlanner.action(leader: leader(playing: false), leaderNow: epoch, local: local("Other", elapsed: 10, playing: false), localLatency: 0, drift: nil, seek: seek) == .none)
    }

    @Test func aPausedMemberNearTheSpotJustPlays() {
        #expect(JamPlanner.action(leader: leader(), leaderNow: epoch.addingTimeInterval(1), local: local(elapsed: 50.5, playing: false), localLatency: 0, drift: nil, seek: seek) == .resume(at: nil))
        #expect(JamPlanner.action(leader: leader(), leaderNow: epoch.addingTimeInterval(2), local: local(elapsed: 10, playing: false), localLatency: 0, drift: nil, seek: seek) == .resume(at: 52.25))
    }

    @Test func aLeaderWithNothingPlayingStopsAMember() {
        #expect(JamPlanner.action(leader: leader(nil), leaderNow: epoch, local: local(elapsed: 5), localLatency: 0, drift: nil, seek: seek) == .pause)
    }

    @Test func twoVersionsOfASongAreNotTheSameTrack() {
        var state = local("Never Gonna Give You Up", elapsed: 5)
        state.catalogID = "111"
        #expect(!JamPlanner.isSameTrack(state, TrackReference(catalogID: "222", title: "Never Gonna Give You Up (2022 Remaster)", artist: "A", album: "B", duration: 200)))
        #expect(JamPlanner.isSameTrack(state, TrackReference(catalogID: "111", title: "Never Gonna Give You Up (Live)", artist: "A", album: nil, duration: 0)))
        let noIDs = local("Home", elapsed: 5)
        #expect(!JamPlanner.isSameTrack(noIDs, TrackReference(catalogID: nil, title: "Home (Remastered)", artist: "A", album: nil, duration: 0)))
        #expect(!JamPlanner.isSameTrack(noIDs, TrackReference(catalogID: nil, title: "Home", artist: "Someone Else", album: nil, duration: 0)))
        #expect(JamPlanner.isSameTrack(noIDs, TrackReference(catalogID: nil, title: "home", artist: "a", album: nil, duration: 0)))
    }

    @Test func messagesSurviveTheWire() throws {
        let state = leader()
        for message in [JamMessage.invite(state), .join(state.id, plays: true), .setPlays(state.id, member: "M", plays: false), .state(state), .ping(7, sentAt: epoch), .report(state.id, drift: -0.2)] {
            let decoded = try MessageCodec.decode(JamMessage.self, from: MessageCodec.encode(message))
            #expect(String(describing: decoded) == String(describing: message))
        }
        let guest = try MessageCodec.decode(Envelope.self, from: MessageCodec.encode(Envelope.guest(.invite(JamAdvert(id: state.id, hostName: "Mac")))))
        #expect(String(describing: guest).contains("Mac"))
    }

    @Test func aHelloFromAnOlderAppStillDecodes() throws {
        let hello = Hello(info: DeviceInfo(id: "x", name: "Phone", kind: .iPhone), publicKey: Data([1]), nonce: Data([2]), jam: nil)
        var plist = try #require(PropertyListSerialization.propertyList(from: MessageCodec.encode(hello), format: nil) as? [String: Any])
        plist["jam"] = nil
        let old = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(try MessageCodec.decode(Hello.self, from: old).info.name == "Phone")
    }
}

@Suite struct JamTuningTests {
    @Test func aDeviceThatSoundsLateComesOutNegative() {
        // The phone's take began at 60.0 s into the song, this Mac's at 58.5 s. If both sounded together the phone's take
        // would start 1.5 s into the Mac's; it starts 1.47 s in, so the phone's sound is 30 ms behind.
        let offset = JamTuning.offset(lag: 1.47, positions: (other: 60, local: 58.5), drifts: (other: 0, local: 0))
        #expect(abs(offset + 0.03) < 0.0001)
    }

    @Test func driftTheDevicesAlreadyKnewAboutIsNotCountedTwice() {
        // The phone knew it was 20 ms ahead, so only the rest is a latency error.
        let offset = JamTuning.offset(lag: 1.55, positions: (other: 60, local: 58.5), drifts: (other: 0.02, local: 0))
        #expect(abs(offset - 0.03) < 0.0001)
    }
}
