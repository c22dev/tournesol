//
//  SearchView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import MusicKit
import SwiftUI

extension Notification.Name {
    static let showSearch = Notification.Name("ch.cclerc.Tournesol.showSearch")
}

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
        .onReceive(NotificationCenter.default.publisher(for: .showSearch)) { _ in
            if device.isConnected { isPresented = true }
        }
        .sheet(isPresented: $isPresented) {
            SearchView(device: device)
        }
    }
}

// MARK: - Model

enum SearchDestination: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct BrowseItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let artwork: MusicKit.Artwork?
    let destination: SearchDestination
}

struct BrowseSection: Identifiable {
    let id: String
    let title: String
    let items: [BrowseItem]
}

private extension Album {
    var browseItem: BrowseItem { BrowseItem(id: "album-\(id.rawValue)", title: title, subtitle: artistName, artwork: artwork, destination: .album(self)) }
}

private extension Playlist {
    var browseItem: BrowseItem { BrowseItem(id: "playlist-\(id.rawValue)", title: name, subtitle: curatorName, artwork: artwork, destination: .playlist(self)) }
}

private enum TopHit: Identifiable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .song(let song): "song-\(song.id.rawValue)"
        case .album(let album): "album-\(album.id.rawValue)"
        case .artist(let artist): "artist-\(artist.id.rawValue)"
        case .playlist(let playlist): "playlist-\(playlist.id.rawValue)"
        }
    }
}

/// What was searched for lately, kept on this device.
private enum RecentSearches {
    private static let key = "recentSearches"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ term: String) -> [String] {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return load() }
        var terms = load().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        terms.insert(term, at: 0)
        terms = Array(terms.prefix(10))
        UserDefaults.standard.set(terms, forKey: key)
        return terms
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct SearchResults {
    var top: [TopHit] = []
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []

    var isEmpty: Bool { top.isEmpty && songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

private func describe(_ error: Error) -> String {
    if error is CancellationError { return "" }
    if let url = error as? URLError, url.code == .notConnectedToInternet || url.code == .networkConnectionLost {
        return "You're offline. Check your connection and try again."
    }
    let message = error.localizedDescription
    if message.localizedCaseInsensitiveContains("developer token") || message.localizedCaseInsensitiveContains("permission") {
        return "Apple Music refused the request. Make sure MusicKit is enabled for this app's identifier and that access is allowed. (\(message))"
    }
    return message
}

// MARK: - Playback

/// Turns catalog items into commands for the target device.
private struct Player {
    let device: RemoteDevice
    var dismiss: () -> Void

    static func reference(for song: Song) -> TrackReference {
        TrackReference(catalogID: song.id.rawValue, title: song.title, artist: song.artistName, album: song.albumTitle, duration: song.duration ?? 0)
    }

    private static let maxUpcoming = 99

    /// Plays `songs[index]` and queues what follows it.
    func play(_ songs: [Song], from index: Int = 0, shuffled: Bool = false) {
        // A guest can't start songs on the host, only add them to its queue.
        if device.access == .guestHost {
            if songs.indices.contains(index) { queue([songs[index]], next: false) }
            return dismiss()
        }
        var songs = songs
        if shuffled { songs.shuffle() }
        guard songs.indices.contains(index) else { return }
        let tracks = songs.map(Self.reference(for:))
        let upcoming = Array(tracks.dropFirst(index + 1).prefix(Self.maxUpcoming))
        device.send(.loadTrack(tracks[index], at: 0, upcoming: upcoming))
        device.send(.startLoaded(at: 0))
        dismiss()
    }

    func queue(_ songs: [Song], next: Bool) {
        let tracks = songs.map(Self.reference(for:))
        guard !tracks.isEmpty else { return }
        device.send(tracks.count == 1 ? .enqueue(tracks[0], next: next) : .enqueueAll(tracks, next: next))
    }
}


// MARK: - Browse

/// Recents, your playlists and recommendations. Anything that fails to load is just left out.
enum BrowseLoader {
    static func sections() async -> [BrowseSection] {
        async let recents = recentlyPlayed()
        async let playlists = libraryPlaylists()
        async let recommended = recommendations()
        return await ([recents, playlists].compactMap { $0 }) + recommended
    }

    private static func recentlyPlayed() async -> BrowseSection? {
        var request = MusicRecentlyPlayedContainerRequest()
        request.limit = 12
        guard let response = try? await request.response() else { return nil }
        let items = response.items.compactMap { item -> BrowseItem? in
            switch item {
            case .album(let album): album.browseItem
            case .playlist(let playlist): playlist.browseItem
            default: nil
            }
        }
        return items.isEmpty ? nil : BrowseSection(id: "recents", title: "Recently Played", items: items)
    }

    // The Mac's library backend crashes on some sort keys, so playlists are sorted here.
    private static func libraryPlaylists() async -> BrowseSection? {
        guard let response = try? await MusicLibraryRequest<Playlist>().response() else { return nil }
        let recent = response.items.sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }.prefix(25)
        let items = recent.map(\.browseItem)
        return items.isEmpty ? nil : BrowseSection(id: "library", title: "Your Playlists", items: items)
    }

    private static func recommendations() async -> [BrowseSection] {
        var request = MusicPersonalRecommendationsRequest()
        request.limit = 6
        guard let response = try? await request.response() else { return [] }
        return response.recommendations.compactMap { recommendation in
            let items = recommendation.items.compactMap { item -> BrowseItem? in
                switch item {
                case .album(let album): album.browseItem
                case .playlist(let playlist): playlist.browseItem
                default: nil
                }
            }
            guard let title = recommendation.title, !items.isEmpty else { return nil }
            return BrowseSection(id: "recommendation-\(recommendation.id.rawValue)", title: title, items: items)
        }
    }
}

// MARK: - Search

struct SearchView: View {
    let device: RemoteDevice
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var path: [SearchDestination] = []
    @State private var isAuthorized = MusicAuthorization.currentStatus == .authorized
    @State private var browse: [BrowseSection] = []
    @State private var suggestions: [String] = []
    @State private var recents = RecentSearches.load()

    private var player: Player { Player(device: device) { dismiss() } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !isAuthorized {
                    ContentUnavailableView {
                        Label("Apple Music Access Needed", systemImage: "music.note")
                    } description: {
                        Text("Allow Tournesol to access Apple Music to search the catalog.")
                    } actions: {
                        Button("Allow Access") { Task { await requestAccess() } }
                    }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Search Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await search(debounce: false) } }
                    }
                } else if query.isEmpty, browse.isEmpty {
                    ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass", description: Text("Plays on \(device.displayName)."))
                } else if query.isEmpty {
                    browseSections
                } else if results.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultSections
                }
            }
            .overlay {
                if isSearching, results.isEmpty, errorMessage == nil { ProgressView() }
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: SearchDestination.self) { destination in
                switch destination {
                case .album(let album): CollectionView(source: .album(album), player: player)
                case .playlist(let playlist): CollectionView(source: .playlist(playlist), player: player)
                case .artist(let artist): ArtistView(artist: artist, player: player, path: $path)
                }
            }
            .searchable(text: $query, prompt: "Songs, albums, artists")
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(recents, id: \.self) { term in
                        Label(term, systemImage: "clock.arrow.circlepath").searchCompletion(term)
                    }
                    if !recents.isEmpty {
                        Button("Clear Recent Searches", role: .destructive) {
                            RecentSearches.clear()
                            recents = []
                        }
                    }
                } else {
                    ForEach(suggestions, id: \.self) { term in
                        Text(term).searchCompletion(term)
                    }
                }
            }
            .onSubmit(of: .search) { recents = RecentSearches.add(query) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: query) { await search() }
            .task(id: query) { await loadSuggestions() }
            .task {
                await requestAccess()
                await loadBrowse()
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var browseSections: some View {
        ForEach(browse) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    NavigationLink(value: item.destination) {
                        ItemRow(title: item.title, subtitle: item.subtitle, artwork: item.artwork, round: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if !results.top.isEmpty {
            Section("Top Results") {
                ForEach(results.top) { hit in
                    switch hit {
                    case .song(let song):
                        SongRow(song: song, player: player) { play([song], from: 0) }
                            #if os(iOS)
                            .swipeActions(edge: .leading) { songActions(song) }
                            #endif
                    case .album(let album):
                        NavigationLink(value: SearchDestination.album(album)) {
                            ItemRow(title: album.title, subtitle: "Album · \(album.artistName)", artwork: album.artwork, round: false)
                        }
                    case .artist(let artist):
                        NavigationLink(value: SearchDestination.artist(artist)) {
                            ItemRow(title: artist.name, subtitle: "Artist", artwork: artist.artwork, round: true)
                        }
                    case .playlist(let playlist):
                        NavigationLink(value: SearchDestination.playlist(playlist)) {
                            ItemRow(title: playlist.name, subtitle: "Playlist · \(playlist.curatorName ?? "Apple Music")", artwork: playlist.artwork, round: false)
                        }
                    }
                }
            }
        }
        if !results.songs.isEmpty {
            Section("Songs") {
                ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, player: player) {
                        play(results.songs, from: index)
                    }
                    #if os(iOS)
                    .swipeActions(edge: .leading) { songActions(song) }
                    #endif
                }
            }
        }
        if !results.albums.isEmpty {
            Section("Albums") {
                ForEach(results.albums) { album in
                    NavigationLink(value: SearchDestination.album(album)) {
                        ItemRow(title: album.title, subtitle: album.artistName, artwork: album.artwork, round: false)
                    }
                }
            }
        }
        if !results.artists.isEmpty {
            Section("Artists") {
                ForEach(results.artists) { artist in
                    NavigationLink(value: SearchDestination.artist(artist)) {
                        ItemRow(title: artist.name, subtitle: nil, artwork: artist.artwork, round: true)
                    }
                }
            }
        }
        if !results.playlists.isEmpty {
            Section("Playlists") {
                ForEach(results.playlists) { playlist in
                    NavigationLink(value: SearchDestination.playlist(playlist)) {
                        ItemRow(title: playlist.name, subtitle: playlist.curatorName, artwork: playlist.artwork, round: false)
                    }
                }
            }
        }
    }

    private func songActions(_ song: Song) -> some View {
        SongMenuItems(song: song, player: player)
    }

    // MARK: Loading

    private func play(_ songs: [Song], from index: Int) {
        recents = RecentSearches.add(query)
        player.play(songs, from: index)
    }

    private func loadSuggestions() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard isAuthorized, !term.isEmpty else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let request = MusicCatalogSearchSuggestionsRequest(term: term, includingTopResultsOfTypes: [])
        guard let response = try? await request.response(), !Task.isCancelled else { return }
        suggestions = response.suggestions.prefix(6).map { $0.searchTerm }
    }

    private func requestAccess() async {
        if MusicAuthorization.currentStatus == .notDetermined {
            isAuthorized = await MusicAuthorization.request() == .authorized
        } else {
            isAuthorized = MusicAuthorization.currentStatus == .authorized
        }
    }

    private func loadBrowse() async {
        guard isAuthorized, browse.isEmpty else { return }
        browse = await BrowseLoader.sections()
    }

    private func search(debounce: Bool = true) async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard isAuthorized, !term.isEmpty else {
            results = SearchResults()
            errorMessage = nil
            return
        }
        if debounce { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
        request.limit = 15
        request.includeTopResults = true
        do {
            let response = try await request.response()
            guard !Task.isCancelled else { return }
            let top: [TopHit] = response.topResults.prefix(5).compactMap { result in
                switch result {
                case .song(let song): .song(song)
                case .album(let album): .album(album)
                case .artist(let artist): .artist(artist)
                case .playlist(let playlist): .playlist(playlist)
                default: nil
                }
            }
            results = SearchResults(top: top, songs: Array(response.songs), albums: Array(response.albums), artists: Array(response.artists), playlists: Array(response.playlists))
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            let message = describe(error)
            if !message.isEmpty { errorMessage = message }
        }
    }

}

// MARK: - Collections

private enum CollectionSource {
    case album(Album)
    case playlist(Playlist)

    var title: String {
        switch self {
        case .album(let album): album.title
        case .playlist(let playlist): playlist.name
        }
    }

    var subtitle: String? {
        switch self {
        case .album(let album): album.artistName
        case .playlist(let playlist): playlist.curatorName
        }
    }

    var artwork: MusicKit.Artwork? {
        switch self {
        case .album(let album): album.artwork
        case .playlist(let playlist): playlist.artwork
        }
    }

    func songs() async throws -> [Song] {
        switch self {
        case .album(let album):
            let detailed = try await album.with([.tracks])
            return (detailed.tracks ?? []).compactMap(\.song)
        case .playlist(let playlist):
            let detailed = try await playlist.with([.tracks])
            return (detailed.tracks ?? []).compactMap(\.song)
        }
    }
}

private extension Track {
    var song: Song? {
        if case .song(let song) = self { return song }
        return nil
    }
}

private struct CollectionView: View {
    let source: CollectionSource
    let player: Player
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ArtworkImage(artwork: source.artwork, side: 96, radius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title).font(.title3.weight(.semibold))
                        if let subtitle = source.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    }
                    .lineLimit(2)
                }
                .listRowBackground(Color.clear)
                if !songs.isEmpty {
                    PlayButtons(songs: songs, player: player)
                        .listRowBackground(Color.clear)
                }
            }
            if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Tracks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Section {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        SongRow(song: song, player: player, showsArtwork: false, number: index + 1) { player.play(songs, from: index) }
                    }
                }
            }
        }
        .navigationTitle(source.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            songs = try await source.songs()
        } catch {
            errorMessage = describe(error)
        }
    }
}

private struct ArtistView: View {
    let artist: Artist
    let player: Player
    @Binding var path: [SearchDestination]
    @State private var topSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Artist", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if !topSongs.isEmpty {
                Section {
                    PlayButtons(songs: topSongs, player: player)
                        .listRowBackground(Color.clear)
                    ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, player: player) { player.play(topSongs, from: index) }
                    }
                } header: {
                    Text("Top Songs")
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        Button {
                            path.append(.album(album))
                        } label: {
                            ItemRow(title: album.title, subtitle: album.releaseDate.map { $0.formatted(.dateTime.year()) }, artwork: album.artwork, round: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detailed = try await artist.with([.topSongs, .albums])
            topSongs = Array(detailed.topSongs ?? [])
            albums = Array(detailed.albums ?? [])
        } catch {
            errorMessage = describe(error)
        }
    }
}

private struct PlayButtons: View {
    let songs: [Song]
    let player: Player

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(songs) } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { player.play(songs, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.queue(songs, next: true) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.queue(songs, next: false) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Rows

private struct ArtworkImage: View {
    let artwork: MusicKit.Artwork?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        AsyncImage(url: artwork?.url(width: Int(side * 3), height: Int(side * 3))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

private struct ItemRow: View {
    let title: String
    let subtitle: String?
    let artwork: MusicKit.Artwork?
    let round: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(artwork: artwork, side: 48, radius: round ? 24 : 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
        }
    }
}

/// What can be done with a song besides playing the list it is in.
private struct SongMenuItems: View {
    let song: Song
    let player: Player

    var body: some View {
        Button("Play", systemImage: "play.fill") { player.play([song]) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.queue([song], next: true) }
            .tint(.orange)
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.queue([song], next: false) }
            .tint(.indigo)
    }
}

private struct SongRow: View {
    let song: Song
    let player: Player
    var showsArtwork = true
    var number: Int?
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            playButton
            Menu {
                SongMenuItems(song: song, player: player)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .contextMenu { SongMenuItems(song: song, player: player) }
    }

    private var playButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if let number {
                    Text("\(number)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }
                if showsArtwork {
                    ArtworkImage(artwork: song.artwork, side: 48, radius: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body.weight(.medium))
                    Text([song.artistName, showsArtwork ? song.albumTitle : nil].compactMap { $0 }.joined(separator: " · "))
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
