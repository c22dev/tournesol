import Foundation
import Testing
@testable import TournesolCore

private func song(_ title: String) -> TrackReference {
    TrackReference(catalogID: nil, title: title, artist: "Artist", album: "Album", duration: 180)
}

private func slot(_ title: String, id: String? = nil) -> QueueSlot {
    QueueSlot(id: id ?? "id-\(title)", track: song(title))
}

/// Applies edits the way Music does: an item is taken out, then put right behind the item it names.
private func apply(_ edits: [QueueEdit], to ids: [String], anchor: String) -> [String] {
    var queue = ids
    for edit in edits {
        switch edit {
        case .remove(let id):
            queue.removeAll { $0 == id }
        case .move(let id, let after):
            queue.removeAll { $0 == id }
            let position = after == anchor ? 0 : (queue.firstIndex(of: after).map { $0 + 1 } ?? queue.count)
            queue.insert(id, at: position)
        }
    }
    return queue
}

@Suite struct QueuePlannerTests {
    private let upcoming = ["A", "B", "C", "D"].map { slot($0) }

    @Test func unchangedOrderNeedsNoEdits() {
        #expect(QueuePlanner.plan(target: upcoming.map(\.track), upcoming: upcoming, anchor: "now") == [])
    }

    @Test func removingASongRemovesItNatively() {
        let target = [song("A"), song("C"), song("D")]
        #expect(QueuePlanner.plan(target: target, upcoming: upcoming, anchor: "now") == [.remove("id-B")])
    }

    @Test func movingUpPlacesItBehindItsNewNeighbour() {
        let target = ["A", "D", "B", "C"].map(song)
        #expect(QueuePlanner.plan(target: target, upcoming: upcoming, anchor: "now") == [.move("id-D", after: "id-A")])
    }

    @Test func movingToTheFrontIsPlacedBehindTheCurrentSong() {
        let target = ["C", "A", "B", "D"].map(song)
        #expect(QueuePlanner.plan(target: target, upcoming: upcoming, anchor: "now") == [.move("id-C", after: "now")])
    }

    @Test func movingDownIsExpressedAsMovingTheOthersUp() {
        let target = ["B", "C", "D", "A"].map(song)
        let edits = QueuePlanner.plan(target: target, upcoming: upcoming, anchor: "now")
        #expect(edits == [.move("id-B", after: "now"), .move("id-C", after: "id-B"), .move("id-D", after: "id-C")])
    }

    @Test func aSongMusicDoesNotHoldCannotBePlannedNatively() {
        let target = [song("A"), song("Z")]
        #expect(QueuePlanner.plan(target: target, upcoming: upcoming, anchor: "now") == nil)
    }

    @Test func withoutIdsOrAnchorNothingIsPlanned() {
        let noIds = [QueueSlot(id: nil, track: song("A")), slot("B")]
        #expect(QueuePlanner.plan(target: [song("A")], upcoming: noIds, anchor: "now") == nil)
        #expect(QueuePlanner.plan(target: [song("A")], upcoming: upcoming, anchor: nil) == nil)
        #expect(QueuePlanner.plan(target: [], upcoming: [], anchor: "now") == nil)
    }

    @Test func editsAlwaysLeaveTheRequestedOrder() {
        let titles = ["A", "B", "C", "D", "E"]
        let slots = titles.map { slot($0) }
        let ids = slots.compactMap(\.id)
        var checked = 0
        for subset in 0..<(1 << titles.count) {
            let kept = titles.indices.filter { subset & (1 << $0) != 0 }.map { titles[$0] }
            for order in permutations(kept) {
                let edits = QueuePlanner.plan(target: order.map(song), upcoming: slots, anchor: "now")
                #expect(edits != nil)
                #expect(apply(edits ?? [], to: ids, anchor: "now") == order.map { "id-\($0)" }, "target \(order)")
                checked += 1
            }
        }
        #expect(checked > 300)
    }

    @Test func aQueueIsOnlyComparedWholeWhenMusicShowsAllOfIt() {
        #expect(QueuePlanner.matches(upcoming, upcoming.map(\.track)))
        #expect(!QueuePlanner.matches(upcoming, [song("A")]))
        #expect(!QueuePlanner.matches(upcoming, ["B", "A", "C", "D"].map(song)))
        let long = (0..<70).map { slot("S\($0)") }
        #expect(QueuePlanner.matches(long, long.prefix(5).map(\.track)))
    }

    @Test func waitingSongsAreThoseStillLeadingTheQueue() {
        let queue = ["X", "Y", "A", "B"].map { slot($0) }
        let both = QueuePlanner.waiting([song("X"), song("Y")], in: queue)
        #expect(both.songs.map(\.title) == ["X", "Y"])
        #expect(both.anchor == "id-Y")
    }

    @Test func aPlayedOrMovedSongEndsTheWaitingRun() {
        let queue = ["Y", "A", "B"].map { slot($0) }
        let afterX = QueuePlanner.waiting([song("X"), song("Y")], in: queue)
        #expect(afterX.songs.isEmpty)
        #expect(afterX.anchor == nil)
        let partly = QueuePlanner.waiting([song("Y"), song("Z")], in: queue)
        #expect(partly.songs.map(\.title) == ["Y"])
        #expect(partly.anchor == "id-Y")
    }

    @Test func holdsChecksTheExactPosition() {
        #expect(QueuePlanner.holds(song("B"), at: 1, in: upcoming))
        #expect(!QueuePlanner.holds(song("B"), at: 0, in: upcoming))
        #expect(!QueuePlanner.holds(song("B"), at: 9, in: upcoming))
    }
}

@Suite struct NativeHealthTests {
    private let start = ContinuousClock.now

    @Test func aFeatureWorksUntilItFailsTwiceInARow() {
        var health = NativeHealth<String>()
        #expect(health.isUsable("edit", now: start))
        #expect(health.failed("edit", now: start) == 1)
        #expect(health.isUsable("edit", now: start))
        #expect(health.failed("edit", now: start) == 2)
        #expect(!health.isUsable("edit", now: start))
    }

    @Test func aSuccessClearsTheCount() {
        var health = NativeHealth<String>()
        health.failed("edit", now: start)
        health.succeeded("edit")
        #expect(health.failed("edit", now: start) == 1)
        #expect(health.isUsable("edit", now: start))
    }

    @Test func aBrokenFeatureIsTriedAgainAfterTheWait() {
        var health = NativeHealth<String>(allowedFailures: 2, retryAfter: .seconds(600))
        health.failed("insert", now: start)
        health.failed("insert", now: start)
        #expect(!health.isUsable("insert", now: start + .seconds(599)))
        #expect(health.isUsable("insert", now: start + .seconds(601)))
    }

    @Test func featuresFailIndependently() {
        var health = NativeHealth<String>()
        health.failed("edit", now: start)
        health.failed("edit", now: start)
        #expect(!health.isUsable("edit", now: start))
        #expect(health.isUsable("start", now: start))
    }
}

private func permutations(_ items: [String]) -> [[String]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[String]] in
        var rest = items
        let head = rest.remove(at: index)
        return permutations(rest).map { [head] + $0 }
    }
}
