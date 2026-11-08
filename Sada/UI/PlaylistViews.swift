import SwiftUI

struct PlaylistCover: View {
    let playlist: Playlist
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let tracks = Array(library.tracks(in: playlist).filter(\.hasArtwork).prefix(4))
        Group {
            if tracks.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ArtworkView(track: tracks[0], cornerRadius: 0, pixelSize: 200)
                        ArtworkView(track: tracks[1], cornerRadius: 0, pixelSize: 200)
                    }
                    GridRow {
                        ArtworkView(track: tracks[2], cornerRadius: 0, pixelSize: 200)
                        ArtworkView(track: tracks[3], cornerRadius: 0, pixelSize: 200)
                    }
                }
            } else if let first = tracks.first {
                ArtworkView(track: first, cornerRadius: 0, pixelSize: 400)
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note.list").font(.title2).foregroundStyle(.white))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var askName = false
    @State private var newName = ""

    var body: some View {
        List {
            Button { askName = true } label: {
                Label("New Playlist…", systemImage: "plus.rectangle.on.rectangle")
            }
            NavigationLink(value: Route.favorites) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.pink, .red], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: "heart.fill").foregroundStyle(.white))
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text("Favorites")
                        Text("\(library.favorites.count) songs").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(library.playlists) { playlist in
                NavigationLink(value: Route.playlist(playlist.id)) {
                    HStack(spacing: 14) {
                        PlaylistCover(playlist: playlist).frame(width: 56, height: 56)
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                            Text("\(playlist.trackIDs.count) songs").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { library.deletePlaylist(library.playlists[i].id) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .alert("New Playlist", isPresented: $askName) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(named: newName); newName = "" }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        if let playlist = library.playlist(id: playlistID) {
            let tracks = library.tracks(in: playlist)
            List {
                VStack(spacing: 14) {
                    PlaylistCover(playlist: playlist)
                        .frame(width: 230, height: 230)
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    Text(playlist.name).font(.title2.bold())
                    PlayShuffleButtons(tracks: tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

                ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                    TrackRow(track: track)
                        .onTapGesture { player.play(tracks, startAt: i) }
                        .contextMenu { TrackMenuItems(track: track) }
                }
                .onDelete { library.removeFromPlaylist(playlistID, at: $0) }
                .onMove { library.movePlaylistItems(playlistID, from: $0, to: $1) }

                if tracks.isEmpty {
                    Text("Add songs with “Add to Playlist…” from any song’s menu.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Button { name = playlist.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    EditButton()
                } label: { Image(systemName: "ellipsis") }
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { library.renamePlaylist(playlistID, to: name) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
        }
    }
}

struct FavoritesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let tracks = library.favorites
        List {
            PlayShuffleButtons(tracks: tracks)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(tracks, startAt: i) }
                    .contextMenu { TrackMenuItems(track: track) }
            }
            if tracks.isEmpty {
                Text("Tap the heart on the player to add songs here.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Favorites")
    }
}
