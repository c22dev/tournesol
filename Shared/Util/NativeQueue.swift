//
//  NativeQueue.swift
//  Tournesol
//

import Foundation

/// An upcoming queue entry. `id` is what edits refer to.
nonisolated struct QueueSlot: Equatable, Sendable {
    var id: String?
    var track: TrackReference
}

nonisolated enum QueueEdit: Equatable, Sendable {
    case remove(String)
    case move(String, after: String)
}

nonisolated enum QueuePlanner {
    /// Music reports at most this many entries.
    static let visibleLimit = 59

    /// Remove and reorder edits that turn `upcoming` into `target`, or nil if that would need an insert.
    /// Items only ever move up: Music takes the item out before counting, so moving down lands one slot early.
    static func plan(target: [TrackReference], upcoming: [QueueSlot], anchor: String?) -> [QueueEdit]? {
        guard let anchor, !upcoming.isEmpty, upcoming.allSatisfy({ $0.id != nil }) else { return nil }
        var unused = upcoming
        var wanted: [String] = []
        for track in target {
            guard let index = unused.firstIndex(where: { $0.track.signature == track.signature }), let id = unused[index].id else { return nil }
            unused.remove(at: index)
            wanted.append(id)
        }
        var edits = unused.compactMap { $0.id.map(QueueEdit.remove) }
        var order = upcoming.compactMap(\.id).filter(wanted.contains)
        for (position, id) in wanted.enumerated() where order[position] != id {
            order.insert(order.remove(at: order.firstIndex(of: id)!), at: position)
            edits.append(.move(id, after: position == 0 ? anchor : wanted[position - 1]))
        }
        return edits
    }

    static func matches(_ upcoming: [QueueSlot], _ target: [TrackReference]) -> Bool {
        guard upcoming.count >= target.count, upcoming.count == target.count || upcoming.count >= visibleLimit else { return false }
        return zip(upcoming, target).allSatisfy { TrackMatcher.sameSong($0.track.title, $1.title) }
    }

    /// The songs we queued that are still waiting at the front, and the queue item the last one sits at.
    static func waiting(_ expected: [TrackReference], in upcoming: [QueueSlot]) -> (songs: [TrackReference], anchor: String?) {
        var matched = 0
        for (slot, song) in zip(upcoming, expected) {
            guard TrackMatcher.sameSong(slot.track.title, song.title) else { break }
            matched += 1
        }
        return (Array(expected.prefix(matched)), matched > 0 ? upcoming[matched - 1].id : nil)
    }

    static func holds(_ track: TrackReference, at index: Int, in upcoming: [QueueSlot]) -> Bool {
        upcoming.indices.contains(index) && TrackMatcher.sameSong(upcoming[index].track.title, track.title)
    }
}

/// Skips a broken private-API feature for a while so its fallback runs instead.
nonisolated struct NativeHealth<Feature: Hashable> {
    let allowedFailures: Int
    let retryAfter: Duration
    private var failures: [Feature: (count: Int, last: ContinuousClock.Instant)] = [:]

    init(allowedFailures: Int = 2, retryAfter: Duration = .seconds(600)) {
        self.allowedFailures = allowedFailures
        self.retryAfter = retryAfter
    }

    func isUsable(_ feature: Feature, now: ContinuousClock.Instant = .now) -> Bool {
        guard let failure = failures[feature], failure.count >= allowedFailures else { return true }
        return now - failure.last > retryAfter
    }

    mutating func succeeded(_ feature: Feature) {
        failures[feature] = nil
    }

    @discardableResult
    mutating func failed(_ feature: Feature, now: ContinuousClock.Instant = .now) -> Int {
        let count = (failures[feature]?.count ?? 0) + 1
        failures[feature] = (count, now)
        return count
    }
}
