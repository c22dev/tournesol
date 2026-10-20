//
//  QueueView.swift
//  Tournesol
//

import MusicKit
import SwiftUI

extension Notification.Name {
    static let showQueue = Notification.Name("ch.cclerc.Tournesol.showQueue")
}

struct QueueButton: View {
    let device: RemoteDevice
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!device.isConnected)
        .opacity(device.isConnected ? 1 : 0.35)
        .help("Up Next")
        .accessibilityLabel("Up Next")
        .onReceive(NotificationCenter.default.publisher(for: .showQueue)) { _ in
            if device.isConnected { isPresented = true }
        }
        .sheet(isPresented: $isPresented) {
            QueueView(device: device)
        }
    }
}

/// Small covers for queue rows, fetched when a row first appears and kept for the next time it does.
@MainActor
final class RowArtworkCache {
    static let shared = RowArtworkCache()
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func data(for track: TrackReference) async -> Data? {
        let key = track.catalogID ?? track.signature
        if let data = cache[key] { return data }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await Self.fetch(track) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            if cache.count > 300 { cache.removeAll() }
            cache[key] = data
        }
        return data
    }

    private nonisolated static func fetch(_ track: TrackReference) async -> Data? {
        if let id = track.catalogID, id.allSatisfy(\.isNumber), MusicAuthorization.currentStatus == .authorized {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            if let song = try? await request.response().items.first,
               let url = song.artwork?.url(width: 160, height: 160),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                return data
            }
        }
        return await CatalogLookup.resolve(track, needsArtwork: true).artwork
    }
}

private struct TrackArtwork: View {
    let track: TrackReference
    @State private var image: PlatformImage?

    var body: some View {
        ArtworkView(image: image, cornerRadius: 6)
            .frame(width: 44, height: 44)
            .task(id: track.signature) {
                image = await RowArtworkCache.shared.data(for: track).flatMap(PlatformImage.init(data:))
            }
    }
}

struct QueueView: View {
    let device: RemoteDevice
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [QueueEntry] = []
    @State private var hasLoaded = false
    @State private var lastEdit = Date.distantPast

    private struct QueueEntry: Identifiable, Equatable {
        let id = UUID()
        var track: TrackReference
    }

    private var isEditable: Bool { device.hasEditableQueue }

    /// A double-click on the Mac, where a single click selects and starts drags.
    #if os(macOS)
    private static let tapsToPlay = 2
    #else
    private static let tapsToPlay = 1
    #endif

    var body: some View {
        NavigationStack {
            List {
                if device.state.hasTrack {
                    Section("Now Playing") {
                        HStack(spacing: 12) {
                            ArtworkView(image: device.artwork, cornerRadius: 6)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.state.title ?? "")
                                    .font(.body.weight(.medium))
                                if let artist = device.state.artist {
                                    Text(artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: device.state.isPlaying)
                                .foregroundStyle(device.accent.accent.color)
                                .accessibilityLabel(device.state.isPlaying ? "Playing" : "Paused")
                        }
                    }
                }
                Section {
                    ForEach(tracks) { entry in
                        // not a Button: on the Mac it would take the mouse-down and the list could never start a drag
                        row(entry.track)
                            .onTapGesture(count: Self.tapsToPlay) { play(entry) }
                            .accessibilityAddTraits(.isButton)
                        .contextMenu {
                            Button("Play Now", systemImage: "play.fill") { play(entry) }
                            if isEditable {
                                Button("Play Next", systemImage: "text.insert") { moveToTop(entry) }
                                Button("Move Up", systemImage: "chevron.up") { shift(entry, by: -1) }
                                Button("Move Down", systemImage: "chevron.down") { shift(entry, by: 1) }
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                            }
                        }
                        .moveDisabled(!isEditable)
                        .deleteDisabled(!isEditable)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: remove)
                } header: {
                    upNextHeader
                }
            }
            .overlay {
                if hasLoaded, tracks.isEmpty {
                    ContentUnavailableView("Nothing Up Next", systemImage: "list.bullet", description: Text("Songs you add from search appear here."))
                }
            }
            .navigationTitle(device.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                if isEditable, !tracks.isEmpty {
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", systemImage: "trash") {
                            tracks = []
                            commit()
                        }
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    await reload()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func row(_ track: TrackReference) -> some View {
        HStack(spacing: 12) {
            TrackArtwork(track: track)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? "Unknown")
                    .font(.body.weight(.medium))
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var summary: String? {
        guard !tracks.isEmpty else { return nil }
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let total = tracks.reduce(0) { $0 + $1.track.duration }
        guard total > 0 else { return count }
        return count + " · " + Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var upNextHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Up Next")
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            Spacer()
            if device.access == .full {
                HStack(spacing: 14) {
                    if let shuffle = device.state.shuffle {
                        Button { device.send(.setShuffle(!shuffle)) } label: { Image(systemName: "shuffle") }
                            .foregroundStyle(shuffle ? device.accent.accent.color : .secondary)
                            .help("Shuffle")
                            .accessibilityLabel("Shuffle")
                            .accessibilityValue(shuffle ? "On" : "Off")
                    }
                    if let mode = device.state.repeatMode {
                        Button { device.send(.setRepeat(mode.next)) } label: { Image(systemName: mode == .one ? "repeat.1" : "repeat") }
                            .foregroundStyle(mode != .off ? device.accent.accent.color : .secondary)
                            .help("Repeat")
                            .accessibilityLabel("Repeat")
                            .accessibilityValue(mode.rawValue.capitalized)
                    }
                }
                .buttonStyle(.borderless)
                .font(.body)
                .textCase(nil)
            }
        }
    }

    private func reload() async {
        // no answer is not an empty queue: keep what's shown
        guard let fetched = await device.upcomingTracks() else { return }
        guard Date.now.timeIntervalSince(lastEdit) > 3 else { return }
        hasLoaded = true
        guard fetched != tracks.map(\.track) else { return }
        tracks = fetched.map { QueueEntry(track: $0) }
    }

    private func commit() {
        lastEdit = .now
        device.send(.setQueue(tracks.map(\.track)))
    }

    private func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    private func shift(_ entry: QueueEntry, by offset: Int) {
        guard let index = tracks.firstIndex(of: entry), tracks.indices.contains(index + offset) else { return }
        tracks.swapAt(index, index + offset)
        commit()
    }

    private func moveToTop(_ entry: QueueEntry) {
        guard let index = tracks.firstIndex(of: entry), index > 0 else { return }
        tracks.move(fromOffsets: [index], toOffset: 0)
        commit()
    }

    private func remove(_ entry: QueueEntry) {
        guard let index = tracks.firstIndex(of: entry) else { return }
        tracks.remove(at: index)
        commit()
    }

    private func remove(at offsets: IndexSet) {
        tracks.remove(atOffsets: offsets)
        commit()
    }

    private func play(_ entry: QueueEntry) {
        guard let index = tracks.firstIndex(of: entry) else { return }
        let rest = Array(tracks.dropFirst(index + 1).map(\.track))
        device.send(.loadTrack(entry.track, at: 0, upcoming: rest))
        device.send(.startLoaded(at: 0))
        dismiss()
    }
}
