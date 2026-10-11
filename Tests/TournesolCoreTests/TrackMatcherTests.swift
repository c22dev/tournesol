import Foundation
import Testing
@testable import TournesolCore

private func wanted(_ title: String, artist: String? = nil, album: String? = nil, duration: TimeInterval = 0) -> TrackReference {
    TrackReference(catalogID: nil, title: title, artist: artist, album: album, duration: duration)
}

@Suite struct TrackMatcherTests {
    @Test func exactMatchIsConfident() {
        let score = TrackMatcher.score(title: "Nights", artist: "Frank Ocean", album: "Blonde", duration: 307, against: wanted("Nights", artist: "Frank Ocean", album: "Blonde", duration: 307))
        #expect(score >= TrackMatcher.confident)
    }

    @Test func differentTitleNeverMatches() {
        #expect(TrackMatcher.score(title: "Ivy", artist: "Frank Ocean", album: nil, duration: nil, against: wanted("Nights", artist: "Frank Ocean")) == 0)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(TrackMatcher.normalize("  Béyoncé ") == TrackMatcher.normalize("beyonce"))
        #expect(TrackMatcher.sameSong("Don’t Stop", "don't stop"))
    }

    @Test func decorationsMatchWeakly() {
        let plain = TrackMatcher.score(title: "Song", artist: "A", album: nil, duration: nil, against: wanted("Song", artist: "A"))
        let decorated = TrackMatcher.score(title: "Song (Remastered 2011)", artist: "A", album: nil, duration: nil, against: wanted("Song", artist: "A"))
        #expect(decorated > 0)
        #expect(decorated < plain)
        #expect(TrackMatcher.sameSong("Song [Live]", "Song"))
    }

    @Test func wrongArtistIsPenalised() {
        let right = TrackMatcher.score(title: "Song", artist: "Alice", album: nil, duration: nil, against: wanted("Song", artist: "Alice"))
        let wrong = TrackMatcher.score(title: "Song", artist: "Bob", album: nil, duration: nil, against: wanted("Song", artist: "Alice"))
        #expect(wrong < TrackMatcher.acceptable)
        #expect(right > wrong)
    }

    @Test func featuredArtistsStillMatch() {
        let score = TrackMatcher.score(title: "Song", artist: "Alice & Bob", album: nil, duration: nil, against: wanted("Song", artist: "Alice"))
        #expect(score >= TrackMatcher.acceptable)
    }

    @Test func singleSuffixDoesNotHideAlbum() {
        let score = TrackMatcher.score(title: "Song", artist: "A", album: "Album - Single", duration: nil, against: wanted("Song", artist: "A", album: "Album"))
        let other = TrackMatcher.score(title: "Song", artist: "A", album: "Other", duration: nil, against: wanted("Song", artist: "A", album: "Album"))
        #expect(score > other)
    }

    @Test func durationBreaksTies() {
        let close = TrackMatcher.score(title: "Song", artist: "A", album: nil, duration: 200, against: wanted("Song", artist: "A", duration: 201))
        let far = TrackMatcher.score(title: "Song", artist: "A", album: nil, duration: 260, against: wanted("Song", artist: "A", duration: 201))
        #expect(close > far)
    }

    @Test func missingTitleScoresZero() {
        #expect(TrackMatcher.score(title: "Song", artist: "A", album: nil, duration: nil, against: TrackReference(catalogID: nil, title: nil, artist: "A", album: nil, duration: 0)) == 0)
    }
}
