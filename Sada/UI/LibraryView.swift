import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showSettings = false
    @State private var importMode: ImportMode?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    /// Albums in the order you last played them.
    private var recentlyPlayedAlbums: [Album] {
        var seen = Set<String>()
        var out: [Album] = []
        for t in library.recentlyPlayed where seen.insert(t.albumID).inserted {
            if let a = library.album(id: t.albumID) { out.append(a) }
            if out.count >= 30 { break }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        LibraryCategoryRow(title: "Playlists", icon: "music.note.list", count: library.playlists.count, route: .playlists)
                        Divider().padding(.leading, 52)
                        LibraryCategoryRow(title: "Favorites", icon: "heart", count: library.favorites.count, route: .favorites)
                        Divider().padding(.leading, 52)
                        LibraryCategoryRow(title: "Artists", icon: "music.microphone", count: library.artists.count, route: .artists)
                        Divider().padding(.leading, 52)
                        LibraryCategoryRow(title: "Albums", icon: "square.stack", count: library.albums.count, route: .albums)
                        Divider().padding(.leading, 52)
                        LibraryCategoryRow(title: "Songs", icon: "music.note", count: library.tracks.count, route: .songs)
                        Divider().padding(.leading, 52)
                        LibraryCategoryRow(title: "Your Stats", icon: "chart.bar.xaxis", count: library.plays.count, route: .stats)
                    }
                    .padding(.horizontal)

                    let recent = recentlyPlayedAlbums
                    Text("Recently Played")
                        .font(.title2.bold())
                        .padding(.horizontal)
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    if recent.isEmpty {
                        Text("Albums you play will show up here.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(recent) { album in
                                NavigationLink(value: Route.album(album.id)) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 24)
            }
            .brandHeader(TabSettings.name(.library))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .libraryDestinations()
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
struct LibraryCategoryRow: View {
    let title: String
    let icon: String
    let count: Int
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                Text(title).font(.title3)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Songs

enum SongSort: String, CaseIterable, Identifiable {
    case title = "Title", artist = "Artist", recent = "Recently Added", plays = "Most Played"
    var id: String { rawValue }
}

struct SongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @AppStorage("songSort") private var sort: SongSort = .title
    @State private var filter = ""

    private var songs: [Track] {
        var list = library.tracks
        switch sort {
        case .title: break
        case .artist:
            list.sort {
                let a = $0.displayArtist.localizedStandardCompare($1.displayArtist)
                return a == .orderedSame
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : a == .orderedAscending
            }
        case .recent: list.sort { $0.dateAdded > $1.dateAdded }
        case .plays: list.sort { $0.playCount > $1.playCount }
        }
        guard !filter.isEmpty else { return list }
        let key = filter.searchKey
        return list.filter { $0.title.searchKey.contains(key) || $0.displayArtist.searchKey.contains(key) || $0.displayAlbum.searchKey.contains(key) }
    }

    var body: some View {
        let list = songs
        List {
            PlayShuffleButtons(tracks: list)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(list, startAt: i) }
                    .trackContextMenu(track)
                    .swipeActions(edge: .leading) {
                        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(.indigo)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { player.addToQueue(track) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                            .tint(.orange)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Songs")
        .searchable(text: $filter, prompt: "Filter songs")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SongSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }
}
