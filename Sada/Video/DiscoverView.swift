import SwiftUI

struct OnlineTitleRoute: Hashable {
    let type: String
    let id: String
    let name: String
}

/// Netflix-style browsing of online movies & series from Stremio addons.
struct DiscoverView: View {
    @State private var addons = AddonStore.shared
    @State private var rows: [(id: String, title: String, items: [MetaPreview])] = []
    @State private var ytRows: [YouTubeRow] = []
    @State private var openingVideo: String?
    @Environment(AppRouter.self) private var router
    @State private var loading = false
    @State private var query = ""
    @State private var results: [MetaPreview] = []
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                SearchBar(text: $query, focused: $searchFocused, onSubmit: { Task { await search() } },
                          onCancel: { query = ""; results = []; searchFocused = false })
                    .padding(.horizontal)

                if !query.isEmpty && (searching || !results.isEmpty) {
                    if searching {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    } else {
                        posterGrid(results)
                    }
                } else if addons.catalogAddons.isEmpty {
                    ContentUnavailableView("No Sources", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Add addons in Settings › Videos & Player › Online Sources."))
                } else {
                    if let hero = rows.first?.items.first { HeroBanner(item: hero) }
                    ForEach(ytRows) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Text(row.title).font(.title3.bold())
                                Image(systemName: "play.rectangle.fill").foregroundStyle(.red).font(.subheadline)
                            }
                            .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(row.items) { v in
                                        Button { Task { await playYouTube(v) } } label: {
                                            YouTubeCard(item: v)
                                                .overlay {
                                                    if openingVideo == v.id {
                                                        ProgressView().controlSize(.large)
                                                            .frame(width: 220, height: 124)
                                                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                                            .frame(maxHeight: .infinity, alignment: .top)
                                                    }
                                                }
                                        }
                                        .buttonStyle(PressableStyle())
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.horizontal)
                            }
                            .scrollTargetBehavior(.viewAligned)
                        }
                    }
                    if rows.isEmpty && loading {
                        ForEach(0..<3, id: \.self) { _ in SkeletonCarousel() }
                    }
                    ForEach(rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.title).font(.title3.bold()).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(row.items) { item in
                                        NavigationLink(value: OnlineTitleRoute(type: item.type, id: item.id, name: item.name)) {
                                            RemotePoster(url: item.poster, title: item.name).frame(width: 118)
                                        }
                                        .buttonStyle(PressableStyle())
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.horizontal)
                            }
                            .scrollTargetBehavior(.viewAligned)
                        }
                    }

                }
            }
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .task {
            await addons.ensureDefaults()
            if rows.isEmpty { await load() }
        }
        .refreshable { await load() }
        .navigationDestination(for: OnlineTitleRoute.self) { OnlineTitleView(route: $0) }
    }

    private func posterGrid(_ items: [MetaPreview]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: OnlineTitleRoute(type: item.type, id: item.id, name: item.name)) {
                    VStack(alignment: .leading, spacing: 4) {
                        RemotePoster(url: item.poster, title: item.name)
                        Text(item.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                        if let r = item.releaseInfo { Text(r).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal)
    }

    private func playYouTube(_ v: YouTubeVideos.Result) async {
        openingVideo = v.id
        defer { openingVideo = nil }
        if let item = await YouTubeVideos.item(for: v) { router.playingVideo = item }
    }

    private func loadYouTubeRows() async {
        let region = UserDefaults.standard.string(forKey: "online.region") ?? "EG"
        let built = await withTaskGroup(of: YouTubeRow?.self) { group in
            for q in YouTubeRow.queries {
                group.addTask {
                    let items = await YouTubeVideos.search(q.query, length: .long, region: region)
                        .filter { $0.verified && $0.seconds >= 40 * 60 }
                    return items.count >= 3 ? YouTubeRow(id: q.id, title: q.title, items: Array(items.prefix(15))) : nil
                }
            }
            var out: [YouTubeRow] = []
            for await row in group { if let row { out.append(row) } }
            return out
        }
        let order = YouTubeRow.queries.map(\.id)
        withAnimation { ytRows = built.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let yt: Void = loadYouTubeRows()
        var built: [(String, String, [MetaPreview])] = []
        for addon in addons.catalogAddons {
            for catalog in (addon.catalogs ?? []).filter({ !$0.needsExtra && ["movie", "series"].contains($0.type) }).prefix(6) {
                let items = await StremioClient.catalog(addon, catalog)
                guard !items.isEmpty else { continue }
                let typeName = catalog.type == "movie" ? "Movies" : "Series"
                let title = catalog.name.map { "\($0) \(typeName)" } ?? typeName
                built.append(("\(addon.id)-\(catalog.type)-\(catalog.id)", title, items))
            }
        }
        withAnimation { rows = built.map { (id: $0.0, title: $0.1, items: $0.2) } }
        await yt
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchFocused = false
        searching = true
        var found: [MetaPreview] = []
        for addon in addons.catalogAddons {
            for catalog in (addon.catalogs ?? []).filter({ $0.supportsSearch && ["movie", "series"].contains($0.type) }) {
                found += await StremioClient.catalog(addon, catalog, search: q)
            }
        }
        var seen = Set<String>()
        results = found.filter { seen.insert($0.id).inserted }
        searching = false
    }
}

struct RemotePoster: View {
    let url: String?
    let title: String

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: url.flatMap(URL.init(string:)), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).padding(6)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
    }
}

struct HeroBanner: View {
    let item: MetaPreview

    var body: some View {
        NavigationLink(value: OnlineTitleRoute(type: item.type, id: item.id, name: item.name)) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: (item.background ?? item.poster).flatMap(URL.init(string:))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary).shimmering() }
                }
                .frame(height: 230)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.title.bold()).foregroundStyle(.white).lineLimit(2)
                    Text([item.releaseInfo, item.imdbRating.map { "★ \($0)" }, item.genres?.prefix(2).joined(separator: ", ")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Title page

struct OnlineTitleView: View {
    let route: OnlineTitleRoute
    @State private var meta: MetaDetail?
    @State private var season = 1
    @State private var streamTarget: StreamTarget?

    struct StreamTarget: Identifiable {
        let id: String // video id for the stream request
        let title: String
        let episode: MetaDetail.Video?
    }

    var body: some View {
        ScrollView {
            if let meta {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: (meta.background ?? meta.poster).flatMap(URL.init(string:))) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                        }
                        .frame(height: 300)
                        .clipped()
                        LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom)
                        HStack(alignment: .bottom, spacing: 14) {
                            RemotePoster(url: meta.poster, title: meta.name).frame(width: 100)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meta.name).font(.title2.bold()).lineLimit(2)
                                Text([meta.releaseInfo, meta.runtime, meta.imdbRating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let g = meta.genres, !g.isEmpty {
                                    Text(g.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding()
                    }

                    if meta.type == "movie" {
                        Button { streamTarget = StreamTarget(id: meta.id, title: meta.name, episode: nil) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .adaptiveButton(prominent: true)
                        .controlSize(.large)
                        .padding(.horizontal)
                    }

                    if let d = meta.description {
                        Text(d).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    if let cast = meta.cast, !cast.isEmpty {
                        Text("Starring: " + cast.prefix(5).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }

                    if let videos = meta.videos, meta.type == "series", !videos.isEmpty {
                        let seasons = Array(Set(videos.compactMap(\.season))).filter { $0 > 0 }.sorted()
                        if seasons.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(seasons, id: \.self) { s in
                                        Button("Season \(s)") { season = s }
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(season == s ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                                            .foregroundStyle(season == s ? .white : .primary)
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        LazyVStack(spacing: 12) {
                            ForEach(videos.filter { ($0.season ?? 1) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) { v in
                                Button {
                                    streamTarget = StreamTarget(id: v.id, title: meta.name, episode: v)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        AsyncImage(url: v.thumbnail.flatMap(URL.init(string:))) { phase in
                                            if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                                        }
                                        .frame(width: 140, height: 79)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(v.episode ?? 0). \(v.displayTitle)").font(.subheadline.weight(.semibold)).lineLimit(2)
                                            if let o = v.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                        }
                                        .foregroundStyle(.primary)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 30)
            } else {
                ProgressView().padding(.top, 120)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(meta == nil ? route.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard meta == nil else { return }
            meta = await AddonStore.shared.meta(type: route.type, id: route.id)
            if let first = meta?.videos?.compactMap(\.season).filter({ $0 > 0 }).min() { season = first }
        }
        .sheet(item: $streamTarget) { target in
            StreamPickerSheet(type: route.type, target: target, meta: meta)
                .presentationDetents([.medium, .large])
        }
    }
}

struct StreamPickerSheet: View {
    let type: String
    let target: OnlineTitleView.StreamTarget
    let meta: MetaDetail?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var streams: [StreamOption] = []
    @State private var loading = true
    @State private var opening: UUID?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ForEach(0..<5, id: \.self) { _ in SkeletonRow() }
                } else if streams.isEmpty {
                    Text("No legal source found for this title on YouTube or the Internet Archive. You can add more sources in Settings › Videos & Player › Online Sources.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(streams) { s in
                        Button { Task { await play(s) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: s.isTorrent ? "xmark.circle" : (s.ytId != nil ? "play.rectangle.fill" : "play.circle.fill"))
                                    .font(.title2)
                                    .foregroundStyle(s.playable ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    if let sub = s.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    Text(s.isTorrent ? "\(s.addon) · torrent (not supported)" : s.addon)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if opening == s.id { ProgressView() }
                            }
                            .foregroundStyle(s.playable ? .primary : .secondary)
                        }
                        .disabled(!s.playable)
                    }
                }
            }
            .navigationTitle(target.episode.map { "E\($0.episode ?? 0) · \($0.displayTitle)" } ?? target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                async let builtIn = BuiltInSources.streams(type: type, meta: meta, videoID: target.id, episode: target.episode)
                async let addons = AddonStore.shared.streams(type: type, id: target.id)
                streams = await builtIn + addons
                loading = false
            }
        }
    }

    private func play(_ s: StreamOption) async {
        opening = s.id
        defer { opening = nil }
        var url = s.url
        var audio: URL?
        if url == nil, let yt = s.ytId, let streams = await YouTubeVideos.playableStreams(yt) {
            url = streams.video
            audio = streams.audio
        }
        guard let url else { return }
        var item: VideoItem
        if let ep = target.episode {
            item = .remote(url: url, title: target.title, kind: .episode, show: target.title,
                           season: ep.season, episode: ep.episode, episodeTitle: ep.displayTitle)
        } else {
            item = .remote(url: url, title: target.title, kind: .movie)
        }
        item.audioURL = audio?.absoluteString
        dismiss()
        try? await Task.sleep(for: .milliseconds(350))
        router.playingVideo = item
    }
}

// MARK: - Settings › Online Sources

struct AddonSettingsView: View {
    @State private var store = AddonStore.shared
    @State private var newURL = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(store.addons) { addon in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(addon.name).font(.body.weight(.medium))
                        Text(addon.resources.map(\.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.remove(at: $0) }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Installed")
            }
            Section {
                TextField("https://…/manifest.json", text: $newURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task {
                        error = nil
                        do {
                            try await store.add(newURL)
                            newURL = ""
                        } catch {
                            self.error = "Couldn't load that addon. Check the link."
                        }
                    }
                } label: {
                    HStack { Text("Add Addon"); if store.loading { Spacer(); ProgressView() } }
                }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Add Cinemeta (posters & catalogs)") { Task { try? await store.add(AddonStore.cinemeta) } }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            } header: {
                Text("Add")
            } footer: {
                Text("Uses the same addon links as Nuvio/Stremio: in Nuvio open the addon and copy its manifest link. Direct (HTTP) and YouTube sources play in MHM; torrent-only sources aren't supported. Addons running on your PC need its network address (not 127.0.0.1) and the PC must be on the same Wi-Fi.")
            }
        }
        .navigationTitle("Online Sources")
        .toolbar { EditButton() }
    }
}
