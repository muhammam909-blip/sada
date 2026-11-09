import SwiftUI

struct OnlineView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var feed = OnlineFeed.shared
    @AppStorage("recentOnlineSearches") private var recentRaw = ""
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var results: [OnlineSong] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchedFor = ""
    @FocusState private var focused: Bool
    @State private var showSettings = false

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private var showingSearch: Bool { focused || !searchedFor.isEmpty || !query.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBar(text: $query, focused: $focused, onSubmit: { Task { await run(query) } }, onCancel: cancelSearch)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                ZStack {
                    if showingSearch {
                        searchContent
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        OnlineHomeFeed()
                            .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.3), value: showingSearch)
            }
            .navigationTitle("Online")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsPageSheet { OnlineSettingsView() } }
            .navigationDestination(for: Genre.self) { GenreView(genre: $0) }
            .navigationDestination(for: FeedSection.self) { FeedSectionView(section: $0) }
            .task(id: query) {
                guard focused, !query.isEmpty, query != searchedFor else { suggestions = []; return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let found = await SearchSuggestions.fetch(query)
                withAnimation(.snappy) { suggestions = found }
            }
            .onAppear(perform: consumeRouterQuery)
            .onChange(of: router.onlineQuery) { _, _ in consumeRouterQuery() }
        }
    }

    // MARK: Search screen

    @ViewBuilder private var searchContent: some View {
        List {
            if focused && !query.isEmpty && query != searchedFor {
                // Typing: suggestions
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        query = s
                        Task { await run(s) }
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text(s).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                                .onTapGesture { query = s }
                        }
                    }
                    .transition(.opacity)
                }
            } else if query.isEmpty && searchedFor.isEmpty {
                // Focused but empty: recent searches
                if recent.isEmpty {
                    Text("Search for any song or artist.").foregroundStyle(.secondary).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(recent, id: \.self) { term in
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(term)
                                Spacer()
                                Button { removeRecent(term) } label: {
                                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { query = term; Task { await run(term) } }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear All") { withAnimation { recentRaw = "" } }.font(.caption)
                        }
                    }
                }
            } else if loading {
                ForEach(0..<8, id: \.self) { _ in SkeletonRow().listRowSeparator(.hidden) }
            } else {
                let local = localMatches
                if !local.isEmpty {
                    Section {
                        ForEach(Array(local.prefix(5).enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track)
                                .overlay(alignment: .trailing) { SourceBadge(local: true) }
                                .onTapGesture { player.play(Array(local.prefix(5)), startAt: i) }
                                .contextMenu { TrackMenuItems(track: track) }
                        }
                    } header: {
                        Label("On Your iPhone", systemImage: "iphone").font(.subheadline.weight(.semibold))
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                if !results.isEmpty {
                    Section {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, song in
                            OnlineSongRow(song: song, isCurrent: player.current?.id == "yt:\(song.id)")
                                .contentShape(Rectangle())
                                .onTapGesture { player.playOnline(results, startAt: i) }
                                .contextMenu { OnlineSongMenu(song: song, list: results, index: i) }
                                .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                    } header: {
                        HStack {
                            Label("Online", systemImage: "globe").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                for song in results where !library.contains(title: song.title, artist: song.artist) {
                                    DownloadManager.shared.download(song)
                                }
                            } label: {
                                Label("Download All", systemImage: "arrow.down.circle").font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .animation(.snappy, value: results.map(\.id))
        .animation(.snappy, value: loading)
    }

    private var localMatches: [Track] {
        let key = searchedFor.searchKey
        guard !key.isEmpty else { return [] }
        return library.tracks.filter { $0.title.searchKey.contains(key) || $0.displayArtist.searchKey.contains(key) }
    }

    private func cancelSearch() {
        query = ""
        searchedFor = ""
        results = []
        error = nil
        suggestions = []
        focused = false
    }

    private func removeRecent(_ term: String) {
        withAnimation { recentRaw = recent.filter { $0 != term }.joined(separator: "\n") }
    }

    private func consumeRouterQuery() {
        guard let q = router.onlineQuery, !q.isEmpty else { return }
        router.onlineQuery = nil
        query = q
        Task { await run(q) }
    }

    private func run(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        focused = false
        suggestions = []
        searchedFor = q
        loading = true
        error = nil
        var list = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentRaw = list.prefix(12).joined(separator: "\n")
        do {
            let found = try await feed.search(q)
            results = found
            if found.isEmpty { error = "No songs found online." }
            // Warm up the first streams so tapping plays instantly.
            for song in found.prefix(3) { Task { _ = await OnlineStreams.shared.resolve(song.id) } }
        } catch {
            results = []
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Search bar with clear (×) button

struct SearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Songs, artists on YouTube Music", text: $text)
                    .focused(focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                if !text.isEmpty {
                    Button {
                        text = ""
                        focused.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.quaternary.opacity(0.6), in: Capsule())

            if focused.wrappedValue || !text.isEmpty {
                Button("Cancel", action: onCancel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: text.isEmpty)
        .animation(.snappy, value: focused.wrappedValue)
    }
}

// MARK: - Home feed

struct OnlineHomeFeed: View {
    @Environment(PlayerEngine.self) private var player
    @State private var feed = OnlineFeed.shared

    private let genreColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !feed.recentlyPlayed.isEmpty {
                    SongCarousel(title: "Recently Streamed", subtitle: nil, songs: feed.recentlyPlayed, section: nil)
                }

                if feed.sections.isEmpty && feed.loading {
                    ForEach(0..<3, id: \.self) { _ in SkeletonCarousel() }
                } else {
                    ForEach(feed.sections) { section in
                        SongCarousel(title: section.title, subtitle: section.subtitle, songs: section.songs, section: section)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Genres & Moods").font(.title2.bold()).padding(.horizontal)
                    LazyVGrid(columns: genreColumns, spacing: 12) {
                        ForEach(Genre.all) { genre in
                            NavigationLink(value: genre) { GenreTile(genre: genre) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
            .animation(.smooth, value: feed.sections.map(\.id))
        }
        .refreshable { await feed.refreshIfNeeded(force: true) }
        .task { await feed.refreshIfNeeded() }
    }
}

struct SongCarousel: View {
    let title: String
    let subtitle: String?
    let songs: [OnlineSong]
    let section: FeedSection?
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle { Text(subtitle.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(title).font(.title2.bold()).lineLimit(1)
                }
                Spacer()
                if let section {
                    NavigationLink(value: section) {
                        Text("See All").font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(songs.prefix(20).enumerated()), id: \.element.id) { i, song in
                        Button {
                            player.playOnline(songs, startAt: i)
                        } label: {
                            SongCard(song: song, isCurrent: player.current?.id == "yt:\(song.id)")
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu { OnlineSongMenu(song: song, list: songs, index: i) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct SongCard: View {
    let song: OnlineSong
    var isCurrent = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: song.artworkURL ?? song.thumbnailURL, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).shimmering()
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if isCurrent {
                    NowPlayingBars(animating: player.isPlaying)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                } else if library.contains(title: song.title, artist: song.artist) {
                    SourceBadge(local: true).padding(6)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150)
        .foregroundStyle(.primary)
    }
}

struct GenreTile: View {
    let genre: Genre

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: genre.colors.map { Color(hex: String(format: "%06X", $0)) },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: genre.icon)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
                .rotationEffect(.degrees(18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)
            Text(genre.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(12)
        }
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Green "on iPhone" or grey "streaming" capsule.
struct SourceBadge: View {
    let local: Bool

    var body: some View {
        Image(systemName: local ? "checkmark.icloud.fill" : "icloud")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(local ? Color.green : Color.gray, in: Circle())
            .accessibilityLabel(local ? "On your iPhone" : "Online")
    }
}

struct OnlineSongMenu: View {
    let song: OnlineSong
    let list: [OnlineSong]
    let index: Int
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button { player.playOnline(list, startAt: index) } label: { Label("Play", systemImage: "play") }
        Button { player.playNext(OnlineTrack.make(song)) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.startRadio(from: song) } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
        Button { DownloadManager.shared.download(song) } label: { Label("Download", systemImage: "arrow.down.circle") }
    }
}

// MARK: - Skeletons

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 180, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 120, height: 10)
            }
            Spacer()
        }
        .shimmering()
        .padding(.vertical, 2)
    }
}

struct SkeletonCarousel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 200, height: 20).padding(.horizontal)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(width: 150, height: 150)
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 110, height: 10)
                    }
                }
            }
            .padding(.horizontal)
        }
        .shimmering()
    }
}

// MARK: - Genre & section pages

struct GenreView: View {
    let genre: Genre
    @Environment(PlayerEngine.self) private var player
    @State private var songs: [OnlineSong] = []
    @State private var loading = true

    var body: some View {
        List {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: genre.colors.map { Color(hex: String(format: "%06X", $0)) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(genre.name).font(.largeTitle.bold()).foregroundStyle(.white).padding()
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .listRowSeparator(.hidden)

            if loading {
                ForEach(0..<8, id: \.self) { _ in SkeletonRow().listRowSeparator(.hidden) }
            } else {
                Button {
                    player.playOnline(songs.shuffled(), startAt: 0)
                } label: {
                    Label("Shuffle Play", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .adaptiveButton(prominent: true)
                .listRowSeparator(.hidden)
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    OnlineSongRow(song: song, isCurrent: player.current?.id == "yt:\(song.id)")
                        .contentShape(Rectangle())
                        .onTapGesture { player.playOnline(songs, startAt: i) }
                        .contextMenu { OnlineSongMenu(song: song, list: songs, index: i) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard songs.isEmpty else { return }
            songs = (try? await OnlineFeed.shared.search(genre.query)) ?? []
            withAnimation { loading = false }
        }
    }
}

struct FeedSectionView: View {
    let section: FeedSection
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        List {
            ForEach(Array(section.songs.enumerated()), id: \.element.id) { i, song in
                OnlineSongRow(song: song, isCurrent: player.current?.id == "yt:\(song.id)")
                    .contentShape(Rectangle())
                    .onTapGesture { player.playOnline(section.songs, startAt: i) }
                    .contextMenu { OnlineSongMenu(song: song, list: section.songs, index: i) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(section.title)
        .toolbar {
            Button { player.playOnline(section.songs.shuffled(), startAt: 0) } label: { Image(systemName: "shuffle") }
        }
    }
}

struct OnlineSongRow: View {
    let song: OnlineSong
    var isCurrent = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var downloads = DownloadManager.shared

    var body: some View {
        let state = downloads.states[song.id]
        let owned = library.contains(title: song.title, artist: song.artist)
        HStack(spacing: 12) {
            AsyncImage(url: song.thumbnailURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                    if player.isResolving {
                        ProgressView().tint(.white)
                    } else {
                        NowPlayingBars(animating: player.isPlaying).foregroundStyle(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if owned {
                        Image(systemName: "checkmark.icloud.fill").font(.caption2).foregroundStyle(.green)
                    }
                    Text([song.artist, song.album, song.durationText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                        Circle().trim(from: 0, to: p).stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: p)
                    }
                    .frame(width: 24, height: 24)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                default:
                    if owned && state == nil {
                        Text("ON iPHONE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                            .fixedSize()
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
            .frame(minWidth: 32)
            .animation(.snappy, value: state)
        }
        .padding(.vertical, 2)
    }
}
