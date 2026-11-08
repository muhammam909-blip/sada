import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var showImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.tracks.isEmpty {
                    EmptyLibraryView(showImporter: $showImporter)
                        .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        PlayShuffleButtons(tracks: library.tracks)
                            .padding(.horizontal)

                        if let status = library.enrichmentStatus {
                            Label(status, systemImage: "sparkles")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }

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
                            ArtistShelf(artists: Array(library.artists.shuffled().prefix(12)))
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await library.rescan() }
            .libraryDestinations()
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await library.importFiles(urls) }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct EmptyLibraryView: View {
    @Binding var showImporter: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Your library is empty")
                .font(.title2.bold())
            Text("Import songs from Files, or drop them into\nFiles › On My iPhone › Sada › Music.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showImporter = true
            } label: {
                Label("Import Music", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
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
