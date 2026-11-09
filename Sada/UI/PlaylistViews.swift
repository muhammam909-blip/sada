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
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                Button { newName = ""; askName = true } label: {
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
                    .contextMenu {
                        Button { renameText = playlist.name; renaming = playlist } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { library.deletePlaylist(playlist.id) } label: { Label("Delete Playlist", systemImage: "trash") }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { library.playlists[$0].id }
                    ids.forEach(library.deletePlaylist)
                }
                .onMove { library.movePlaylists(from: $0, to: $1) }
            } header: {
                Text("My Playlists")
            }

            Section {
                ForEach(SmartPlaylist.allCases) { smart in
                    NavigationLink(value: Route.smart(smart.rawValue)) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.tint.opacity(0.18))
                                .overlay(Image(systemName: smart.icon).foregroundStyle(.tint))
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(smart.rawValue)
                                Text("\(library.tracks(for: smart).count) songs · updates automatically")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Smart Playlists")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .toolbar { EditButton() }
        .alert("New Playlist", isPresented: $askName) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(named: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let p = renaming { library.renamePlaylist(p.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var name = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        if let playlist = library.playlist(id: playlistID) {
            let tracks = library.tracks(in: playlist)
            List {
                if !editMode.isEditing {
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
                }

                Button { router.trackSheet = .addSongs(playlistID: playlistID) } label: {
                    Label("Add Songs", systemImage: "plus.circle.fill")
                }

                ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                    TrackRow(track: track)
                        .onTapGesture { if !editMode.isEditing { player.play(tracks, startAt: i) } }
                        .trackContextMenu(track)
                }
                .onDelete { library.removeFromPlaylist(playlistID, at: $0) }
                .onMove { library.movePlaylistItems(playlistID, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { name = playlist.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { library.renamePlaylist(playlistID, to: name) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) {
                    library.deletePlaylist(playlistID)
                    dismiss()
                }
            } message: {
                Text("The songs stay in your library.")
            }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
        }
    }
}

struct FavoritesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var editMode: EditMode = .inactive

    var body: some View {
        let tracks = library.favorites
        List {
            if !editMode.isEditing {
                PlayShuffleButtons(tracks: tracks)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            Button { router.trackSheet = .addSongs(playlistID: nil) } label: {
                Label("Add Songs", systemImage: "plus.circle.fill")
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { if !editMode.isEditing { player.play(tracks, startAt: i) } }
                    .trackContextMenu(track)
            }
            .onDelete { library.removeFavorites(at: $0) }
            .onMove { library.moveFavorites(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle("Favorites")
        .toolbar {
            Button(editMode.isEditing ? "Done" : "Edit") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
    }
}

struct SmartPlaylistView: View {
    let smart: SmartPlaylist
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let tracks = library.tracks(for: smart)
        List {
            PlayShuffleButtons(tracks: tracks)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(tracks, startAt: i) }
                    .trackContextMenu(track)
            }
            if tracks.isEmpty {
                Text("Nothing here yet — keep listening!").foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(smart.rawValue)
        .toolbar {
            Button {
                library.createPlaylist(named: smart.rawValue, with: tracks.map(\.id))
            } label: {
                Label("Save as Playlist", systemImage: "square.and.arrow.down")
            }
        }
    }
}
