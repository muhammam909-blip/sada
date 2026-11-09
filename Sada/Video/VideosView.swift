import SwiftUI

enum VideoRoute: Hashable {
    case show(String)
    case movie(String)
    case allShows
    case allMovies
}

struct PosterImage: View {
    let file: String?
    var aspect: CGFloat = 2 / 3
    var cornerRadius: CGFloat = 10
    var placeholderTitle: String?
    @State private var image: UIImage?
    @State private var store = VideoStore.shared

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 6) {
                            Image(systemName: "film").font(.title2)
                            if let placeholderTitle {
                                Text(placeholderTitle).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(file ?? "-")|\(store.artRevision)") {
                guard let url = store.artURL(file) else { image = nil; return }
                let loaded = await Task.detached { ImageUtil.downsample(url: url, maxPixel: 700) }.value
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

struct VideosView: View {
    @State private var store = VideoStore.shared
    @Environment(AppRouter.self) private var router
    @State private var confirmDuplicates = false
    @AppStorage("videos.space") private var space = "library"
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true

    var body: some View {
        Group {
            if space == "discover" && onlineEnabled {
                DiscoverView()
            } else {
                libraryBody
            }
        }
        .safeAreaInset(edge: .top) {
            if onlineEnabled {
                Picker("Videos", selection: $space) {
                    Text("My Videos").tag("library")
                    Text("Discover").tag("discover")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
        .navigationTitle("Videos")
    }

    private var libraryBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let status = store.metadataStatus {
                    Label(status, systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }

                if store.videos.isEmpty {
                    ContentUnavailableView(
                        "No Movies or Series Yet",
                        systemImage: "film.stack",
                        description: Text("Copy or link a folder with videos (MP4, MOV, M4V…). Posters and episode names are added automatically.")
                    )
                    .padding(.top, 60)
                }

                let continueList = store.continueWatching
                if !continueList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Watching").font(.title2.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(continueList) { v in
                                    Button { router.playingVideo = v } label: { ContinueCard(video: v) }
                                        .buttonStyle(PressableStyle())
                                        .contextMenu { VideoMenu(video: v) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                let shows = store.shows
                if !shows.isEmpty {
                    shelf(title: "TV Shows", route: .allShows) {
                        ForEach(shows) { show in
                            NavigationLink(value: VideoRoute.show(show.id)) {
                                PosterCard(file: show.posterFile, title: show.name,
                                           subtitle: show.unwatchedCount > 0 ? "\(show.unwatchedCount) new" : "Watched")
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }

                let movies = store.movies
                if !movies.isEmpty {
                    shelf(title: "Movies", route: .allMovies) {
                        ForEach(movies) { movie in
                            NavigationLink(value: VideoRoute.movie(movie.id)) {
                                PosterCard(file: movie.posterFile, title: movie.title,
                                           subtitle: movie.year.map(String.init), progress: movie.isInProgress ? movie.progress : nil,
                                           watched: movie.watched)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu { VideoMenu(video: movie) }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Videos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await store.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    Button { store.fetchMetadata(force: true) } label: { Label("Refresh Posters & Info", systemImage: "photo.on.rectangle") }
                    Button(role: .destructive) { confirmDuplicates = true } label: { Label("Remove Duplicate Copies", systemImage: "square.on.square.dashed") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .refreshable { await store.rescan() }
        .task { await store.rescan() }
        .confirmationDialog(
            "Delete “\(router.deleteVideoCandidate?.fileName ?? "")”?",
            isPresented: Binding(get: { router.deleteVideoCandidate != nil }, set: { if !$0 { router.deleteVideoCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Video", role: .destructive) {
                if let v = router.deleteVideoCandidate { store.delete(v) }
                router.deleteVideoCandidate = nil
            }
        } message: {
            Text("The file (and its downloaded subtitles) is removed from your iPhone. This can't be undone.")
        }
        .confirmationDialog("Remove duplicate copies?", isPresented: $confirmDuplicates, titleVisibility: .visible) {
            Button("Remove \(store.duplicates.count) Duplicates", role: .destructive) { store.removeDuplicates() }
        } message: {
            Text("Keeps one copy of every video that was added more than once (same name and size).")
        }
        .navigationDestination(for: VideoRoute.self) { route in
            switch route {
            case .show(let id): ShowDetailView(showID: id)
            case .movie(let id): MovieDetailView(videoID: id)
            case .allShows: PosterGrid(title: "TV Shows", items: store.shows.map { .show($0) })
            case .allMovies: PosterGrid(title: "Movies", items: store.movies.map { .movie($0) })
            }
        }
    }

    private func shelf<Content: View>(title: String, route: VideoRoute, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                NavigationLink(value: route) { Text("See All").font(.subheadline.weight(.medium)) }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .scrollTargetLayout()
                    .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct PosterCard: View {
    let file: String?
    let title: String
    var subtitle: String?
    var progress: Double?
    var watched = false
    var width: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PosterImage(file: file, placeholderTitle: title)
                .frame(width: width)
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { g in
                            Capsule().fill(.tint).frame(width: g.size.width * progress, height: 3)
                        }
                        .frame(height: 3)
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width)
    }
}

struct ContinueCard: View {
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(file: video.stillFile ?? video.backdropFile ?? video.posterFile, aspect: 16 / 9,
                        placeholderTitle: video.showName ?? video.title)
                .frame(width: 250)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 6)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.tint).frame(width: g.size.width * video.progress)
                        }
                    }
                    .frame(height: 4)
                    .padding(8)
                }
            Text(video.kind == .episode ? (video.showName ?? video.title) : video.title)
                .font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            Text(video.kind == .episode ? "\(video.episodeCode ?? "") · \(formatTime(max(video.duration - video.position, 0))) left"
                                        : "\(formatTime(max(video.duration - video.position, 0))) left")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 250)
    }
}

struct VideoMenu: View {
    let video: VideoItem
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { router.playingVideo = video } label: { Label(video.isInProgress ? "Resume" : "Play", systemImage: "play.fill") }
        Button { VideoStore.shared.setWatched(video.id, !video.watched) } label: {
            Label(video.watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: video.watched ? "eye.slash" : "eye")
        }
        Divider()
        Button(role: .destructive) { router.deleteVideoCandidate = video } label: {
            Label("Delete Video", systemImage: "trash")
        }
    }
}

// MARK: - Grid

struct PosterGrid: View {
    enum Item: Identifiable {
        case show(VideoShow), movie(VideoItem)
        var id: String {
            switch self {
            case .show(let s): "s-\(s.id)"
            case .movie(let m): "m-\(m.id)"
            }
        }
    }

    let title: String
    let items: [Item]
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { item in
                    switch item {
                    case .show(let s):
                        NavigationLink(value: VideoRoute.show(s.id)) {
                            PosterCard(file: s.posterFile, title: s.name, subtitle: "\(s.episodes.count) episodes", width: 108)
                        }
                        .buttonStyle(PressableStyle())
                    case .movie(let m):
                        NavigationLink(value: VideoRoute.movie(m.id)) {
                            PosterCard(file: m.posterFile, title: m.title, subtitle: m.year.map(String.init),
                                       progress: m.isInProgress ? m.progress : nil, watched: m.watched, width: 108)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
    }
}

// MARK: - Show detail

struct ShowDetailView: View {
    let showID: String
    @State private var store = VideoStore.shared
    @Environment(AppRouter.self) private var router
    @State private var season = 1

    var body: some View {
        if let show = store.show(id: showID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(show)
                    if show.seasons.count > 1 {
                        Picker("Season", selection: $season) {
                            ForEach(show.seasons, id: \.self) { Text("Season \($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(show.episodes.filter { ($0.season ?? 1) == season }) { ep in
                            Button { router.playingVideo = ep } label: { EpisodeRow(episode: ep) }
                                .buttonStyle(PressableStyle())
                                .contextMenu { VideoMenu(video: ep) }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                Menu {
                    Button { store.setWatched(show: show, true) } label: { Label("Mark All Watched", systemImage: "eye") }
                    Button { store.setWatched(show: show, false) } label: { Label("Mark All Unwatched", systemImage: "eye.slash") }
                } label: { Image(systemName: "ellipsis") }
            }
            .onAppear { season = show.nextUp?.season ?? show.seasons.first ?? 1 }
        } else {
            ContentUnavailableView("Show not found", systemImage: "tv")
        }
    }

    private func header(_ show: VideoShow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                PosterImage(file: show.backdropFile ?? show.posterFile, aspect: 16 / 10, cornerRadius: 0)
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                HStack(alignment: .bottom, spacing: 14) {
                    PosterImage(file: show.posterFile, placeholderTitle: show.name).frame(width: 96).shadow(radius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.name).font(.title.bold()).foregroundStyle(.white).lineLimit(2)
                        Text([show.year.map(String.init), show.genres, show.rating.map { String(format: "★ %.1f", $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()
            }
            if let next = show.nextUp {
                Button { router.playingVideo = next } label: {
                    Label(next.isInProgress ? "Resume \(next.episodeCode ?? "")" : "Play \(next.episodeCode ?? "")", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveButton(prominent: true)
                .controlSize(.large)
                .padding(.horizontal)
            }
            if let overview = show.overview {
                Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(5).padding(.horizontal)
            }
        }
    }
}

struct EpisodeRow: View {
    let episode: VideoItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(file: episode.stillFile ?? episode.backdropFile, aspect: 16 / 9, cornerRadius: 8, placeholderTitle: episode.episodeCode)
                .frame(width: 150)
                .overlay(alignment: .bottom) {
                    if episode.isInProgress {
                        GeometryReader { g in Capsule().fill(.tint).frame(width: g.size.width * episode.progress, height: 3) }
                            .frame(height: 3).padding(5)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(episode.episode ?? 0). \(episode.displayTitle)").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if episode.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if episode.duration > 0 {
                    Text(formatTime(episode.duration)).font(.caption).foregroundStyle(.secondary)
                }
                Text(episode.fileName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Movie detail

struct MovieDetailView: View {
    let videoID: String
    @State private var store = VideoStore.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let movie = store.video(id: videoID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .bottom) {
                        PosterImage(file: movie.posterFile, aspect: 16 / 11, cornerRadius: 0)
                            .blur(radius: 30)
                            .overlay(LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom))
                        PosterImage(file: movie.posterFile, placeholderTitle: movie.title)
                            .frame(width: 170)
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                            .offset(y: 30)
                    }
                    .padding(.bottom, 30)
                    VStack(spacing: 6) {
                        Text(movie.title).font(.title.bold()).multilineTextAlignment(.center)
                        Text([movie.year.map(String.init), movie.genres, movie.duration > 0 ? formatTime(movie.duration) : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    Button { router.playingVideo = movie } label: {
                        Label(movie.isInProgress ? "Resume · \(formatTime(movie.duration - movie.position)) left" : "Play",
                              systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .adaptiveButton(prominent: true)
                    .controlSize(.large)
                    .padding(.horizontal)
                    if movie.isInProgress {
                        Button("Start from Beginning") {
                            store.updateProgress(movie.id, position: 0, duration: movie.duration)
                            router.playingVideo = store.video(id: movie.id)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let overview = movie.overview {
                        Text(overview).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    Text(movie.fileName).font(.caption).foregroundStyle(.tertiary).padding(.horizontal)
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                Menu { VideoMenu(video: movie) } label: { Image(systemName: "ellipsis") }
            }
        } else {
            ContentUnavailableView("Movie not found", systemImage: "film")
        }
    }
}
