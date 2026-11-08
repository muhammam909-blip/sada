import SwiftUI

struct OnlineView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage("recentOnlineSearches") private var recentRaw = ""
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var results: [OnlineSong] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchedFor = ""
    @FocusState private var searchFocused: Bool

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40).listRowSeparator(.hidden)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).listRowSeparator(.hidden)
                } else if results.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, song in
                            OnlineSongRow(song: song, isCurrent: player.current?.id == "yt:\(song.id)")
                                .contentShape(Rectangle())
                                .onTapGesture { player.playOnline(results, startAt: i) }
                                .contextMenu {
                                    Button { player.playOnline(results, startAt: i) } label: { Label("Play", systemImage: "play") }
                                    Button { player.playNext(OnlineTrack.make(song)) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                    Button { DownloadManager.shared.download(song) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Songs for “\(searchedFor)”")
                            Spacer()
                            Button {
                                for song in results { DownloadManager.shared.download(song) }
                            } label: {
                                Label("Download All", systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                if let message = player.onlineError, player.current?.isOnline == true {
                    Text(message).font(.footnote).foregroundStyle(.red).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Online")
            .searchable(text: $query, prompt: "Songs or artists on YouTube Music")
            .searchFocused($searchFocused)
            .searchSuggestions {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        query = s
                        Task { await run(s) }
                    } label: {
                        Label(s, systemImage: "magnifyingglass")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onSubmit(of: .search) { Task { await run(query) } }
            .task(id: query) {
                guard !query.isEmpty, query != searchedFor else { suggestions = []; return }
                try? await Task.sleep(for: .milliseconds(220)) // debounce typing
                guard !Task.isCancelled else { return }
                suggestions = await SearchSuggestions.fetch(query)
            }
            .onAppear(perform: consumeRouterQuery)
            .onChange(of: router.onlineQuery) { _, _ in consumeRouterQuery() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Listen to anything", systemImage: "globe")
                .font(.headline)
            Text("Search, tap a song to play it right away, and download the ones you like — they're saved offline with artwork and lyrics.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)

        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { term in
                    Button {
                        query = term
                        Task { await run(term) }
                    } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear") { recentRaw = "" }.font(.caption)
                }
            }
        }
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
        searchFocused = false
        suggestions = []
        searchedFor = q
        loading = true
        error = nil
        var list = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentRaw = list.prefix(10).joined(separator: "\n")
        do {
            results = try await YTMusicSearch.search(q)
            if results.isEmpty { error = "No songs found." }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
            AsyncImage(url: song.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ArtworkPlaceholder(seed: song.id)
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
                        Circle().trim(from: 0, to: p).stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
