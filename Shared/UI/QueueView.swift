//
//  QueueView.swift
//  Tournesol
//

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

    var body: some View {
        NavigationStack {
            List {
                if device.state.hasTrack {
                    Section("Now Playing") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.state.title ?? "")
                                .font(.body.weight(.medium))
                            if let artist = device.state.artist {
                                Text(artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }
                }
                Section("Up Next") {
                    ForEach(tracks) { entry in
                        HStack {
                            Button { play(entry) } label: { row(entry.track) }
                                .buttonStyle(.plain)
                            #if os(macOS)
                            if isEditable { reorderControls(entry) }
                            #endif
                        }
                        .contextMenu {
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
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title ?? "Unknown")
                .font(.body.weight(.medium))
            Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func reload() async {
        let fetched = await device.upcomingTracks()
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

    private func reorderControls(_ entry: QueueEntry) -> some View {
        HStack(spacing: 4) {
            Button { shift(entry, by: -1) } label: { Image(systemName: "chevron.up") }
                .help("Move up")
            Button { shift(entry, by: 1) } label: { Image(systemName: "chevron.down") }
                .help("Move down")
            Button { remove(entry) } label: { Image(systemName: "xmark") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
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
