import SwiftUI
import UniformTypeIdentifiers

/// Folders tab: Music (On My iPhone, nPlayer style) and Videos (movies & series).
struct FoldersTab: View {
    enum Space: String, CaseIterable, Identifiable {
        case music = "Music", videos = "Videos"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @State private var importMode: ImportMode?
    @State private var showSettings = false
    @AppStorage("folders.space") private var space: Space = .music
    @AppStorage(TabSettings.videosTabKey) private var videosSeparate = false

    var body: some View {
        NavigationStack {
            Group {
                if space == .videos && !videosSeparate {
                    VideosView()
                } else if library.tracks.isEmpty && library.linkedFolders.isEmpty && !library.isScanning {
                    ScrollView {
                        EmptyLibraryView(importMode: $importMode).padding(.top, 80)
                    }
                } else {
                    FolderBrowserView(sourceID: nil, path: "", title: "On My iPhone", isRoot: true)
                }
            }
            .safeAreaInset(edge: .top) {
                if !videosSeparate {
                    Picker("Space", selection: $space) {
                        ForEach(Space.allCases) { Label($0.rawValue, systemImage: $0 == .music ? "music.note" : "film").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AddMusicMenu(mode: $importMode)
                }
            }
            .libraryDestinations()
            .addMusicImporter($importMode)
            .sheet(isPresented: $showSettings) {
                if space == .videos && !videosSeparate {
                    SettingsPageSheet { VideoSettingsView() }
                } else {
                    SettingsPageSheet { FoldersSettingsPage() }
                }
            }
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
            .adaptiveButton(prominent: true)
            .controlSize(.large)
            Button {
                importMode = .copyFiles
            } label: {
                Label("Copy Files & Folders", systemImage: "folder.badge.plus")
            }
            .adaptiveButton()
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
