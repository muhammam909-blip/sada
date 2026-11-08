import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case library = "Your Library", online = "Online"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var query = ""
    @State private var scope: Scope = .library
    @State private var online: [OnlineSong] = []
    @State private var onlineLoading = false
    @State private var onlineError: String?
    @State private var lastOnlineQuery = ""

    var body: some View {
        NavigationStack {
            List {
                Picker("Search in", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch scope {
                case .library: libraryResults
                case .online: onlineResults
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: scope == .library ? "Songs, albums, artists" : "Search YouTube Music")
            .onSubmit(of: .search) { if scope == .online { Task { await runOnline() } } }
            .onChange(of: scope) { _, s in
                if s == .online, !query.isEmpty, query != lastOnlineQuery { Task { await runOnline() } }
            }
            .libraryDestinations()
        }
    }

    // MARK: Library

    @ViewBuilder private var libraryResults: some View {
        let key = query.searchKey
        if key.isEmpty {
            Section("Browse") {
                NavigationLink(value: Route.songs) { Label("All Songs", systemImage: "music.note") }
                NavigationLink(value: Route.albums) { Label("All Albums", systemImage: "square.stack") }
                NavigationLink(value: Route.artists) { Label("All Artists", systemImage: "music.microphone") }
                NavigationLink(value: Route.playlists) { Label("Playlists", systemImage: "music.note.list") }
            }
        } else {
            let songs = library.tracks.filter { $0.title.searchKey.contains(key) || $0.displayArtist.searchKey.contains(key) }
            let albums = library.albums.filter { $0.title.searchKey.contains(key) || $0.artist.searchKey.contains(key) }
            let artists = library.artists.filter { $0.name.searchKey.contains(key) }

            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists.prefix(5)) { artist in
                        NavigationLink(value: Route.artist(artist.id)) {
                            HStack(spacing: 12) {
                                ArtworkView(track: artist.artworkTrack, cornerRadius: 22, pixelSize: 132)
                                    .frame(width: 44, height: 44)
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums.prefix(8)) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            HStack(spacing: 12) {
                                ArtworkView(track: album.artworkTrack, cornerRadius: 6, pixelSize: 132)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading) {
                                    Text(album.title).lineLimit(1)
                                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !songs.isEmpty {
                let shown = Array(songs.prefix(60))
                Section("Songs") {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(shown, startAt: i) }
                            .contextMenu { TrackMenuItems(track: track) }
                    }
                }
            }
            if songs.isEmpty && albums.isEmpty && artists.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView.search(text: query)
                    Button("Search Online") {
                        scope = .online
                    }
                    .buttonStyle(.glass)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: Online

    @ViewBuilder private var onlineResults: some View {
        if onlineLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40).listRowSeparator(.hidden)
        } else if let onlineError {
            Text(onlineError).foregroundStyle(.secondary).listRowSeparator(.hidden)
        } else if online.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Find songs you don't have", systemImage: "arrow.down.circle")
                    .font(.headline)
                Text("Type a song or artist and press Search. Downloads are saved offline in your library with artwork and lyrics.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        } else {
            ForEach(online) { song in
                OnlineSongRow(song: song)
            }
        }
    }

    private func runOnline() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        lastOnlineQuery = q
        onlineLoading = true
        onlineError = nil
        do {
            online = try await YTMusicSearch.search(q)
            if online.isEmpty { onlineError = "No songs found." }
        } catch {
            onlineError = error.localizedDescription
        }
        onlineLoading = false
    }
}

struct OnlineSongRow: View {
    let song: OnlineSong
    @Environment(LibraryStore.self) private var library
    @State private var downloads = DownloadManager.shared

    var body: some View {
        let state = downloads.states[song.id]
        let owned = library.contains(title: song.title, artist: song.artist)
        HStack(spacing: 12) {
            AsyncImage(url: song.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ArtworkPlaceholder(seed: song.id)
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text([song.artist, song.album, song.durationText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Group {
                switch state {
                case .preparing, .finishing:
                    ProgressView()
                case .downloading(let p):
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: p).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 24, height: 24)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                default:
                    if owned && state == nil {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button {
                            downloads.download(song)
                        } label: {
                            Image(systemName: state == nil ? "arrow.down.circle" : "arrow.clockwise.circle")
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.title2)
            .frame(width: 32)
            .animation(.default, value: state)
        }
        .padding(.vertical, 2)
    }
}
