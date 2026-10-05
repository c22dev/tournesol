//
//  CatalogLookup.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import Foundation
import MusicKit

enum CatalogLookup {
    struct Result {
        var catalogID: String?
        var artwork: Data?
    }

    static func requestAuthorization() async {
        if MusicAuthorization.currentStatus == .notDetermined {
            _ = await MusicAuthorization.request()
        }
    }

    static func resolve(_ track: TrackReference, needsArtwork: Bool, allowLooseMatch: Bool = false) async -> Result {
        var result = Result(catalogID: track.catalogID)
        let threshold = allowLooseMatch ? TrackMatcher.loose : TrackMatcher.acceptable

        if MusicAuthorization.currentStatus == .authorized, let song = await song(for: track, threshold: threshold) {
            result.catalogID = song.id.rawValue
            if needsArtwork, let url = song.artwork?.url(width: 600, height: 600), url.scheme?.hasPrefix("http") == true {
                result.artwork = await download(url)
            }
        }

        if result.catalogID == nil || (needsArtwork && result.artwork == nil), let fallback = await iTunesLookup(track, threshold: threshold) {
            result.catalogID = result.catalogID ?? fallback.trackId.map(String.init)
            if needsArtwork, result.artwork == nil,
               let small = fallback.artworkUrl100,
               let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")) {
                result.artwork = await download(url)
            }
        }
        return result
    }

    private static func song(for track: TrackReference, threshold: Int) async -> Song? {
        if let id = track.catalogID {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            return try? await request.response().items.first
        }
        guard let title = track.title else { return nil }

        var best: (song: Song, score: Int)?
        for term in searchTerms(title: title, artist: track.artist, album: track.album) {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            for song in (try? await request.response().songs) ?? [] {
                let score = TrackMatcher.score(title: song.title, artist: song.artistName, album: song.albumTitle, duration: song.duration, against: track)
                if score > best?.score ?? 0 { best = (song, score) }
            }
            if let best, best.score >= TrackMatcher.confident { break }
        }
        return best.flatMap { $0.score >= threshold ? $0.song : nil }
    }

    private static func searchTerms(title: String, artist: String?, album: String?) -> [String] {
        let base = [title, artist].compactMap { $0 }.joined(separator: " ")
        guard let album, !album.isEmpty else { return [base] }
        return ["\(base) \(album)", base]
    }

    private nonisolated struct iTunesResponse: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let trackTimeMillis: Double?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    private static func iTunesLookup(_ track: TrackReference, threshold: Int) async -> iTunesResponse.Item? {
        if let id = track.catalogID {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")
            components?.queryItems = [URLQueryItem(name: "id", value: id)]
            return await iTunesItems(components?.url).first
        }
        guard let title = track.title else { return nil }

        var best: (item: iTunesResponse.Item, score: Int)?
        for term in searchTerms(title: title, artist: track.artist, album: track.album) {
            var components = URLComponents(string: "https://itunes.apple.com/search")
            components?.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "25"),
            ]
            for item in await iTunesItems(components?.url) {
                let score = TrackMatcher.score(title: item.trackName ?? "", artist: item.artistName ?? "", album: item.collectionName, duration: item.trackTimeMillis.map { $0 / 1000 }, against: track)
                if score > best?.score ?? 0 { best = (item, score) }
            }
            if let best, best.score >= TrackMatcher.confident { break }
        }
        return best.flatMap { $0.score >= threshold ? $0.item : nil }
    }

    private static func iTunesItems(_ url: URL?) async -> [iTunesResponse.Item] {
        guard let url,
              let response = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(iTunesResponse.self, from: response.0)
        else { return [] }
        return decoded.results
    }

    private static func download(_ url: URL) async -> Data? {
        guard let response = try? await URLSession.shared.data(from: url) else { return nil }
        return ArtworkEncoding.thumbnail(from: response.0)
    }
}

nonisolated enum TrackMatcher {
    static let loose = 4
    static let acceptable = 8
    static let confident = 14

    static func score(title: String, artist: String, album: String?, duration: TimeInterval?, against track: TrackReference) -> Int {
        guard let wanted = track.title else { return 0 }
        var score = 0

        if normalize(title) == normalize(wanted) {
            score += 6
        } else if stripDecorations(title) == stripDecorations(wanted) {
            score += 1
        } else {
            return 0
        }

        if let wantedArtist = track.artist {
            let lhs = normalize(artist), rhs = normalize(wantedArtist)
            if lhs == rhs { score += 3 } else if lhs.contains(rhs) || rhs.contains(lhs) { score += 2 } else { score -= 3 }
        }

        if let wantedAlbum = track.album, let album {
            if stripAlbumSuffix(album) == stripAlbumSuffix(wantedAlbum) { score += 5 }
        }

        if let duration, track.duration > 0 {
            let delta = abs(duration - track.duration)
            if delta < 2 { score += 3 } else if delta < 5 { score += 1 } else if delta > 15 { score -= 3 }
        }
        return score
    }

    static func sameSong(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return normalize(lhs) == normalize(rhs) || stripDecorations(lhs) == stripDecorations(rhs)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripDecorations(_ text: String) -> String {
        normalize(text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression))
    }

    private static func stripAlbumSuffix(_ text: String) -> String {
        normalize(text.replacingOccurrences(of: #"\s+-\s+(Single|EP)$"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }
}
