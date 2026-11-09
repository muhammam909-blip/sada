import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class VideoStore {
    static let shared = VideoStore()

    nonisolated static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "wmv", "flv", "3gp"]
    /// Formats the built-in Apple player can play directly.
    nonisolated static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    private(set) var videos: [VideoItem] = []
    private(set) var isScanning = false
    var metadataStatus: String?
    private(set) var artRevision = 0

    @ObservationIgnored let artDir: URL
    @ObservationIgnored let subtitlesDir: URL
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var fetching = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sada", isDirectory: true)
        artDir = support.appendingPathComponent("VideoArt", isDirectory: true)
        subtitlesDir = support.appendingPathComponent("Subtitles", isDirectory: true)
        file = support.appendingPathComponent("videos.json")
        for d in [artDir, subtitlesDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([VideoItem].self, from: data) {
            videos = list
        }
    }

    // MARK: Lookup

    func url(for video: VideoItem) -> URL? {
        LibraryStore.shared.rootURL(for: video.sourceID)?.appendingPathComponent(video.relativePath)
    }

    func artURL(_ file: String?) -> URL? { file.map { artDir.appendingPathComponent($0) } }
    func video(id: String) -> VideoItem? { videos.first { $0.id == id } }

    var shows: [VideoShow] {
        Dictionary(grouping: videos.filter { $0.kind == .episode }, by: \.showKey)
            .map { key, items in
                VideoShow(id: key, name: items[0].showName ?? items[0].title,
                          episodes: items.sorted { (($0.season ?? 1), ($0.episode ?? 0)) < (($1.season ?? 1), ($1.episode ?? 0)) })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var movies: [VideoItem] {
        videos.filter { $0.kind == .movie }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var continueWatching: [VideoItem] {
        videos.filter(\.isInProgress).sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
    }

    var recentlyAdded: [VideoItem] { videos.sorted { $0.dateAdded > $1.dateAdded } }

    func show(id: String) -> VideoShow? { shows.first { $0.id == id } }

    func nextEpisode(after video: VideoItem) -> VideoItem? {
        guard video.kind == .episode, let show = show(id: video.showKey),
              let i = show.episodes.firstIndex(where: { $0.id == video.id }), i + 1 < show.episodes.count else { return nil }
        return show.episodes[i + 1]
    }

    /// Subtitle files next to the video ("Movie.srt", "Movie.ar.srt") plus downloaded ones.
    func subtitleFiles(for video: VideoItem) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        if let url = url(for: video) {
            let dir = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                out += items.filter {
                    ["srt", "vtt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.lowercased().hasPrefix(base)
                }
            }
        }
        if let items = try? fm.contentsOfDirectory(at: subtitlesDir, includingPropertiesForKeys: nil) {
            out += items.filter { $0.lastPathComponent.hasPrefix(video.id + ".") }
        }
        return out
    }

    // MARK: Persistence

    private func save() {
        let snapshot = videos
        let target = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
        }
    }

    // MARK: Scanning

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let library = LibraryStore.shared
        var roots: [(String?, URL)] = [(nil, library.documentsURL)]
        for folder in library.linkedFolders {
            if let url = library.rootURL(for: folder.id) { roots.append((folder.id, url)) }
        }
        let snapshot = roots
        let files = await Task.detached(priority: .utility) {
            snapshot.flatMap { LibraryStore.enumerateFiles(in: $0.1, sourceID: $0.0, extensions: VideoStore.videoExtensions) }
        }.value

        let existing = Dictionary(videos.map { ("\($0.sourceID ?? "")|\($0.relativePath)", $0) }, uniquingKeysWith: { a, _ in a })
        var result: [VideoItem] = []
        for f in files {
            if var old = existing[f.key] {
                old.fileSize = f.size
                result.append(old)
                continue
            }
            let folders = f.relativePath.split(separator: "/").dropLast().map(String.init)
            let parsed = VideoNameParser.parse(fileName: (f.relativePath as NSString).lastPathComponent, folders: folders)
            result.append(VideoItem(
                id: LibraryStore.makeID("video|" + f.key), sourceID: f.sourceID, relativePath: f.relativePath,
                fileSize: f.size, modifiedAt: f.modified, dateAdded: Date(),
                kind: parsed.kind, title: parsed.title, showName: parsed.showName, season: parsed.season,
                episode: parsed.episode, year: parsed.year,
                posterFile: nil, backdropFile: nil, stillFile: nil, overview: nil, episodeTitle: nil,
                rating: nil, genres: nil, metaFetched: false,
                position: 0, duration: 0, lastWatched: nil, watched: false
            ))
        }
        if result != videos {
            videos = result
            save()
        }
        fetchMetadata()
    }

    // MARK: Metadata (posters, descriptions, episode names)

    func fetchMetadata(force: Bool = false) {
        guard !fetching else { return }
        fetching = true
        Task {
            defer { fetching = false; metadataStatus = nil }
            // TV shows: one TVmaze lookup per show.
            for show in shows where force || show.episodes.contains(where: { !$0.metaFetched }) {
                metadataStatus = "Getting info for \(show.name)…"
                if let info = await VideoMetadata.show(named: show.name) {
                    let poster = await download(info.posterURL, name: "show-\(LibraryStore.makeID(show.id))-p.jpg")
                    let backdrop = await download(info.backdropURL, name: "show-\(LibraryStore.makeID(show.id))-b.jpg")
                    for ep in show.episodes {
                        let detail = info.episodes["\(ep.season ?? 1)x\(ep.episode ?? 0)"]
                        let still = await download(detail?.imageURL, name: "ep-\(ep.id).jpg")
                        update(ep.id) {
                            $0.showName = info.name
                            $0.posterFile = poster ?? $0.posterFile
                            $0.backdropFile = backdrop ?? $0.backdropFile
                            $0.overview = info.overview
                            $0.genres = info.genres
                            $0.rating = info.rating
                            $0.year = info.year ?? $0.year
                            $0.episodeTitle = detail?.name ?? $0.episodeTitle
                            $0.stillFile = still ?? $0.stillFile
                            if let runtime = detail?.runtime, $0.duration == 0 { $0.duration = Double(runtime * 60) }
                            $0.metaFetched = true
                        }
                    }
                } else {
                    for ep in show.episodes { update(ep.id) { $0.metaFetched = true } }
                }
                artRevision += 1
                save()
            }
            // Movies: Apple's catalogue (works for Arabic films too).
            for movie in movies where force || !movie.metaFetched {
                metadataStatus = "Getting info for \(movie.title)…"
                if let info = await VideoMetadata.movie(title: movie.title, year: movie.year) {
                    let poster = await download(info.posterURL, name: "movie-\(movie.id)-p.jpg")
                    update(movie.id) {
                        $0.posterFile = poster ?? $0.posterFile
                        $0.overview = info.overview
                        $0.genres = info.genres
                        $0.year = $0.year ?? info.year
                        if !info.title.isEmpty { $0.title = info.title }
                        $0.metaFetched = true
                    }
                } else {
                    update(movie.id) { $0.metaFetched = true }
                }
                artRevision += 1
                save()
            }
        }
    }

    private func download(_ url: URL?, name: String) async -> String? {
        guard let url else { return nil }
        let dest = artDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        guard case let (data, 200)? = await HTTP.get(url), let jpeg = ImageUtil.normalizedJPEG(data, maxPixel: 1400) else { return nil }
        try? jpeg.write(to: dest, options: .atomic)
        return name
    }

    // MARK: Mutations

    private func update(_ id: String, _ change: (inout VideoItem) -> Void) {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        change(&videos[i])
    }

    func updateProgress(_ id: String, position: Double, duration: Double) {
        update(id) {
            $0.position = position
            if duration > 0 { $0.duration = duration }
            $0.lastWatched = Date()
            if duration > 0, position / duration > 0.92 { $0.watched = true; $0.position = 0 }
        }
        save()
    }

    func setWatched(_ id: String, _ watched: Bool) {
        update(id) { $0.watched = watched; $0.position = 0 }
        save()
    }

    func setWatched(show: VideoShow, _ watched: Bool) {
        for ep in show.episodes { update(ep.id) { $0.watched = watched; $0.position = 0 } }
        save()
    }

    func rename(_ id: String, title: String, kind: VideoKind, show: String?, season: Int?, episode: Int?) {
        update(id) {
            $0.title = title
            $0.kind = kind
            $0.showName = kind == .episode ? (show ?? title) : nil
            $0.season = season
            $0.episode = episode
            $0.metaFetched = false
            $0.posterFile = nil
        }
        save()
        fetchMetadata()
    }

    func delete(_ video: VideoItem) {
        if let url = url(for: video) { try? FileManager.default.removeItem(at: url) }
        videos.removeAll { $0.id == video.id }
        save()
    }
}
