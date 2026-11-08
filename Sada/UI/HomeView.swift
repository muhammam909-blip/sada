import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var importMode: ImportMode?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.tracks.isEmpty {
                    EmptyLibraryView(importMode: $importMode)
                        .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        PlayShuffleButtons(tracks: library.tracks)
                            .padding(.horizontal)

                        ImportStatusBanner()

                        AlbumShelf(title: "Recently Added", albums: Array(library.recentlyAddedAlbums.prefix(16)))

                        let recent = Array(library.recentlyPlayed.prefix(12))
                        if !recent.isEmpty {
                            TrackShelf(title: "Recently Played", tracks: recent)
                        }

                        let top = Array(library.mostPlayed.prefix(12))
                        if !top.isEmpty {
                            TrackShelf(title: "On Repeat", tracks: top)
                        }

                        if library.artists.count > 1 {
                            ArtistShelf(artists: Array(library.artists.sorted { $0.tracks.count > $1.tracks.count }.prefix(12)))
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AddMusicMenu(mode: $importMode)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await library.rescan() }
            .libraryDestinations()
            .addMusicImporter($importMode)
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct EmptyLibraryView: View {
    @Binding var importMode: ImportMode?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Your library is empty")
                .font(.title2.bold())
            Text("Link your music folder (e.g. from nPlayer) without copying,\nor copy songs into MHM.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                importMode = .linkFolder
            } label: {
                Label("Link a Music Folder", systemImage: "link")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button {
                importMode = .copyFolder
            } label: {
                Label("Copy a Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.glass)
            ImportStatusBanner()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

struct ShelfHeader: View {
    let title: String
    var route: Route?

    var body: some View {
        HStack {
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.bold())
                        Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title2.bold())
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}

struct AlbumShelf: View {
    let title: String
    let albums: [Album]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, route: .albums)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            AlbumCard(album: album, width: 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct TrackShelf: View {
    let title: String
    let tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    private var columns: [[Track]] {
        stride(from: 0, to: tracks.count, by: 4).map { Array(tracks[$0..<min($0 + 4, tracks.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { colIndex, column in
                        VStack(spacing: 10) {
                            ForEach(Array(column.enumerated()), id: \.offset) { rowIndex, track in
                                TrackRow(track: track)
                                    .onTapGesture { player.play(tracks, startAt: colIndex * 4 + rowIndex) }
                                    .contextMenu { TrackMenuItems(track: track) }
                            }
                        }
                        .frame(width: 300)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct ArtistShelf: View {
    let artists: [Artist]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Artists", route: .artists)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(artists) { artist in
                        NavigationLink(value: Route.artist(artist.id)) {
                            VStack(spacing: 8) {
                                ArtworkView(track: artist.artworkTrack, cornerRadius: 60, pixelSize: 300)
                                    .frame(width: 110, height: 110)
                                Text(artist.name).font(.subheadline).lineLimit(1).frame(width: 110)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
