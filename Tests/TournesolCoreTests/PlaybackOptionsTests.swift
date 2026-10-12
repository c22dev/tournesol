import Foundation
import Testing
@testable import TournesolCore

@Suite struct PlaybackOptionsTests {
    @Test func repeatCyclesThroughAllThreeModes() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }

    @Test func airPlayKindsComeFromMusicsNames() {
        #expect(AirPlayDevice(name: "Mac", kindName: "computer", isSelected: true).kind == .computer)
        #expect(AirPlayDevice(name: "TV", kindName: "Apple TV", isSelected: false).kind == .appleTV)
        #expect(AirPlayDevice(name: "Kitchen", kindName: "HomePod", isSelected: false).kind == .homePod)
        #expect(AirPlayDevice(name: "AirPods", kindName: "Bluetooth device", isSelected: false).kind == .bluetooth)
        #expect(AirPlayDevice(name: "?", kindName: "something new", isSelected: false).kind == .other)
    }

    @Test func newSettingsSurviveTheWire() throws {
        var state = PlaybackState()
        state.title = "Song"
        state.shuffle = true
        state.repeatMode = .one
        state.isLiked = true
        state.airPlay = [AirPlayDevice(name: "Kitchen", kind: .homePod, isSelected: true)]
        let decoded = try MessageCodec.decode(PlaybackState.self, from: MessageCodec.encode(state))
        #expect(decoded == state)
    }

    @Test func stateFromAnOlderAppStillDecodes() throws {
        var state = PlaybackState()
        state.title = "Song"
        state.shuffle = true
        var plist = try #require(PropertyListSerialization.propertyList(from: MessageCodec.encode(state), format: nil) as? [String: Any])
        for key in ["shuffle", "repeatMode", "isLiked", "airPlay"] { plist[key] = nil }
        let old = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoded = try MessageCodec.decode(PlaybackState.self, from: old)
        #expect(decoded.title == "Song")
        #expect(decoded.shuffle == nil)
        #expect(decoded.airPlay == nil)
    }

    @Test func newCommandsSurviveTheWire() throws {
        for command in [Command.setShuffle(true), .setRepeat(.all), .setLiked(false), .setAirPlay(["Kitchen", "TV"])] {
            let decoded = try MessageCodec.decode(Command.self, from: MessageCodec.encode(command))
            #expect(String(describing: decoded) == String(describing: command))
        }
    }
}
