import SwiftUI

/// Searches your own library. Online search lives in its own tab.
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true

    var body: some View {
        NavigationStack {
            List { results }
                .listStyle(.plain)
                .brandHeader(TabSettings.name(.search))
                .searchable(text: $query, prompt: "Songs, albums, artists, folders")
                .libraryDestinations()
        }
    }

    @ViewBuilder private var results: some View {
        let key = query.searchKey
        if key.isEmpty {
            Section("Browse") {
                NavigationLink(value: Route.folder(source: nil, path: "", title: "On My iPhone")) { Label("Folders", systemImage: "folder") }
                NavigationLink(value: Route.songs) { Label("All Songs", systemImage: "music.note") }
                NavigationLink(value: Route.albums) { Label("All Albums", systemImage: "square.stack") }
                NavigationLink(value: Route.artists) { Label("All Artists", systemImage: "music.microphone") }
                NavigationLink(value: Route.playlists) { Label("Playlists", systemImage: "music.note.list") }
            }
        } else {
            let songs = library.tracks.filter {
                $0.title.searchKey.contains(key) || $0.displayArtist.searchKey.contains(key)
                    || $0.relativePath.searchKey.contains(key)
            }
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
                            .trackContextMenu(track)
                    }
                }
            }
            if onlineEnabled {
                Section {
                    Button {
                        router.onlineQuery = query
                        router.tab = .online
                    } label: {
                        Label("Search “\(query)” Online", systemImage: "globe")
                    }
                }
            }
            if songs.isEmpty && albums.isEmpty && artists.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowSeparator(.hidden)
            }
        }
    }
}
