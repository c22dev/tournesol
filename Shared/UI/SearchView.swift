//
//  SearchView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import MusicKit
import SwiftUI

struct SearchButton: View {
    let device: RemoteDevice
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!device.isConnected)
        .opacity(device.isConnected ? 1 : 0.35)
        .help("Search Apple Music")
        .accessibilityLabel("Search")
        .sheet(isPresented: $isPresented) {
            SearchView(device: device)
        }
    }
}

struct SearchView: View {
    let device: RemoteDevice
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var isSearching = false
    @State private var isAuthorized = MusicAuthorization.currentStatus == .authorized

    var body: some View {
        NavigationStack {
            List {
                if !isAuthorized {
                    ContentUnavailableView("Apple Music Access Needed", systemImage: "music.note", description: Text("Allow Tournesol to access Apple Music to search the catalog."))
                } else if query.isEmpty {
                    ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass", description: Text("Plays on \(device.displayName)."))
                } else if songs.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(songs) { song in
                        SongRow(song: song) { play(song) }
                            .contextMenu { queueActions(for: song) }
                            #if os(iOS)
                            .swipeActions(edge: .leading) { queueActions(for: song) }
                            #endif
                    }
                }
            }
            .overlay {
                if isSearching, songs.isEmpty { ProgressView() }
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Songs, artists, albums")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: query) { await search() }
            .task {
                if MusicAuthorization.currentStatus == .notDetermined {
                    isAuthorized = await MusicAuthorization.request() == .authorized
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard isAuthorized, !term.isEmpty else {
            songs = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        guard let response = try? await request.response(), !Task.isCancelled else { return }
        songs = Array(response.songs)
    }

    private var supportsQueue: Bool {
        device.info.kind == .iPhone || device.info.kind == .iPad
    }

    @ViewBuilder
    private func queueActions(for song: Song) -> some View {
        Button("Play", systemImage: "play.fill") { play(song) }
        if supportsQueue {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                device.send(.enqueue(reference(for: song), next: true))
            }
            .tint(.orange)
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                device.send(.enqueue(reference(for: song), next: false))
            }
            .tint(.indigo)
        }
    }

    private func reference(for song: Song) -> TrackReference {
        TrackReference(catalogID: song.id.rawValue, title: song.title, artist: song.artistName, album: song.albumTitle, duration: song.duration ?? 0)
    }

    private func play(_ song: Song) {
        let track = reference(for: song)
        device.send(.loadTrack(track, at: 0, upcoming: []))
        device.send(.startLoaded(at: 0))
        dismiss()
    }
}

private struct SongRow: View {
    let song: Song
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                AsyncImage(url: song.artwork?.url(width: 120, height: 120)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body.weight(.medium))
                    Text([song.artistName, song.albumTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if let duration = song.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
