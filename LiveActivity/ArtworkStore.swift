//
//  ArtworkStore.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import UIKit

nonisolated enum ArtworkStore {
    static let groupID = "group.ch.cclerc.Tournesol"

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Artwork", directoryHint: .isDirectory)
    }

    private static func url(for id: String) -> URL? {
        let name = id.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
        return directory?.appending(path: "\(name).jpg")
    }

    static func save(_ data: Data, id: String) {
        guard let directory, let url = url(for: id) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)

        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        sorted.dropFirst(12).forEach { try? manager.removeItem(at: $0) }
    }

    static func image(for id: String?) -> UIImage? {
        guard let id, let url = url(for: id) else { return nil }
        return UIImage(contentsOfFile: url.path(percentEncoded: false))
    }
}
