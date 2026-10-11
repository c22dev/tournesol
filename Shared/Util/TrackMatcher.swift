//
//  TrackMatcher.swift
//  Tournesol
//

import Foundation

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
