import SwiftUI

struct AlbumsGridView: View {
    @Environment(LibraryStore.self) private var library
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.albums) { album in
                    NavigationLink(value: Route.album(album.id)) { AlbumCard(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Albums")
    }
}

struct ArtistsListView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List(library.artists) { artist in
            NavigationLink(value: Route.artist(artist.id)) {
                HStack(spacing: 14) {
                    ArtworkView(track: artist.artworkTrack, cornerRadius: 26, pixelSize: 160)
                        .frame(width: 52, height: 52)
                    Text(artist.name).font(.body)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
    }
}

struct AlbumDetailView: View {
    let albumID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let album = library.album(id: albumID) {
            List {
                VStack(spacing: 14) {
                    ArtworkView(track: album.artworkTrack, cornerRadius: 14, pixelSize: 800)
                        .frame(width: 260, height: 260)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        NavigationLink(value: Route.artist(album.artist.searchKey)) {
                            Text(album.artist).font(.title3).foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        let meta = [album.tracks.first?.genre, album.year.map(String.init)].compactMap { $0 }
                        if !meta.isEmpty {
                            Text(meta.joined(separator: " · "))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    PlayShuffleButtons(tracks: album.tracks)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track, number: track.trackNumber ?? (i + 1))
                        .onTapGesture { player.play(album.tracks, startAt: i) }
                        .contextMenu { TrackMenuItems(track: track) }
                }

                Text("\(album.tracks.count) songs, \(Int(album.totalDuration / 60)) minutes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .padding(.top, 6)
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Album not found", systemImage: "square.stack")
        }
    }
}

struct ArtistDetailView: View {
    let artistID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let artist = library.artist(id: artistID) {
            List {
                VStack(spacing: 14) {
                    ArtworkView(track: artist.artworkTrack, cornerRadius: 90, pixelSize: 600)
                        .frame(width: 180, height: 180)
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                    Text(artist.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    PlayShuffleButtons(tracks: artist.tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

                if artist.albums.count > 0 {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(artist.albums) { album in
                                    NavigationLink(value: Route.album(album.id)) { AlbumCard(album: album, width: 150) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Albums").font(.title2.bold()).foregroundStyle(.primary)
                    }
                }

                Section {
                    ForEach(Array(artist.tracks.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(artist.tracks, startAt: i) }
                            .contextMenu { TrackMenuItems(track: track) }
                    }
                } header: {
                    Text("Songs").font(.title2.bold()).foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Artist not found", systemImage: "music.microphone")
        }
    }
}

