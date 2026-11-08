import CryptoKit
import Foundation
import Observation
import UIKit

struct FileEntry: Sendable {
    let relativePath: String
    let size: Int64
    let modified: Date
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var tracks: [Track] = [] {
        didSet { rebuildIndexes() }
    }
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var isScanning = false
    /// Bumped whenever artwork changes so views reload images.
    private(set) var artworkRevision = 0
    var enrichmentStatus: String?

    nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "alac", "m4b",
    ]

    @ObservationIgnored let documentsURL: URL
    @ObservationIgnored let supportURL: URL
    @ObservationIgnored let artworkDir: URL
    @ObservationIgnored let lyricsDir: URL
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private var indexByID: [String: Int] = [:]

    private var libraryFile: URL { supportURL.appendingPathComponent("library.json") }

    private init() {
        let fm = FileManager.default
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sada", isDirectory: true)
        artworkDir = supportURL.appendingPathComponent("Artwork", isDirectory: true)
        lyricsDir = supportURL.appendingPathComponent("Lyrics", isDirectory: true)
        for dir in [supportURL, artworkDir, lyricsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // A visible folder in Files → On My iPhone → Sada
        try? fm.createDirectory(at: documentsURL.appendingPathComponent("Music", isDirectory: true),
                                withIntermediateDirectories: true)
        load()
    }

    // MARK: - Lookup

    func track(id: String) -> Track? {
        guard let i = indexByID[id], tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    func album(id: String) -> Album? { albums.first { $0.id == id } }
    func artist(id: String) -> Artist? { artists.first { $0.id == id } }

    func url(for track: Track) -> URL { documentsURL.appendingPathComponent(track.relativePath) }
    func artworkFileURL(_ id: String) -> URL { artworkDir.appendingPathComponent("\(id).jpg") }
    func lyricsFileURL(_ id: String) -> URL { lyricsDir.appendingPathComponent("\(id).lrc") }

    func artworkImage(for track: Track, maxPixel: CGFloat = 1200) -> UIImage? {
        guard track.hasArtwork else { return nil }
        return ImageUtil.downsample(url: artworkFileURL(track.id), maxPixel: maxPixel)
    }

    func lyricsText(for track: Track) -> String? {
        guard track.hasLyrics else { return nil }
        return try? String(contentsOf: lyricsFileURL(track.id), encoding: .utf8)
    }

    var recentlyAddedAlbums: [Album] { albums.sorted { $0.dateAdded > $1.dateAdded } }
    var recentlyPlayed: [Track] {
        tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }
    var mostPlayed: [Track] { tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount } }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = decoded
    }

    func save() {
        let snapshot = tracks
        let file = libraryFile
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func rebuildIndexes() {
        var map: [String: Int] = [:]
        for (i, t) in tracks.enumerated() { map[t.id] = i }
        indexByID = map

        let grouped = Dictionary(grouping: tracks, by: \.albumID)
        albums = grouped.map { key, items in
            let sorted = items.sorted {
                ($0.discNumber ?? 1, $0.trackNumber ?? 999, $0.title) < ($1.discNumber ?? 1, $1.trackNumber ?? 999, $1.title)
            }
            return Album(
                id: key,
                title: sorted[0].displayAlbum,
                artist: sorted[0].albumArtistName,
                tracks: sorted,
                year: sorted.compactMap(\.year).first,
                dateAdded: sorted.map(\.dateAdded).max() ?? .distantPast
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let byArtist = Dictionary(grouping: tracks) { $0.albumArtistName.searchKey }
        artists = byArtist.map { key, items in
            let artistAlbums = albums.filter { $0.artist.searchKey == key }
            return Artist(
                id: key,
                name: items[0].albumArtistName,
                tracks: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                albums: artistAlbums
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Scanning

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await rescan()
        MetadataEnricher.shared.start()
    }

    func rescanIfNeeded() async {
        guard didBootstrap, Date().timeIntervalSince(lastScan) > 20 else { return }
        await rescan()
        MetadataEnricher.shared.start()
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; lastScan = Date() }

        let root = documentsURL
        let files = await Task.detached(priority: .utility) { LibraryStore.enumerateAudio(in: root) }.value

        let existing = Dictionary(tracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Track] = []
        result.reserveCapacity(files.count)
        var changed = files.count != tracks.count
        var newSinceFlush = 0

        for file in files {
            if let old = existing[file.relativePath], old.fileSize == file.size,
               abs(old.modifiedAt.timeIntervalSince(file.modified)) < 1 {
                result.append(old)
                continue
            }
            changed = true
            let track = await makeTrack(file, previous: existing[file.relativePath])
            result.append(track)
            newSinceFlush += 1
            if newSinceFlush >= 30 { // show progress on big imports
                newSinceFlush = 0
                tracks = merged(result, keeping: tracks, files: files)
            }
        }

        if changed {
            tracks = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            save()
        }
    }

    /// Intermediate list while a long scan runs: scanned tracks plus untouched old ones.
    private func merged(_ scanned: [Track], keeping old: [Track], files: [FileEntry]) -> [Track] {
        let scannedPaths = Set(scanned.map(\.relativePath))
        let rest = old.filter { !scannedPaths.contains($0.relativePath) }
        return (scanned + rest).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func makeTrack(_ file: FileEntry, previous: Track?) async -> Track {
        let url = documentsURL.appendingPathComponent(file.relativePath)
        let meta = await MetadataReader.read(url: url)
        let id = previous?.id ?? Self.makeID(file.relativePath)

        var hasArtwork = previous?.hasArtwork ?? FileManager.default.fileExists(atPath: artworkFileURL(id).path)
        if let art = meta.artwork {
            let dest = artworkFileURL(id)
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                guard let jpeg = ImageUtil.normalizedJPEG(art) else { return false }
                return (try? jpeg.write(to: dest, options: .atomic)) != nil
            }.value
            if saved { hasArtwork = true; ArtworkCache.shared.invalidate(id) }
        }

        var hasLyrics = previous?.hasLyrics ?? FileManager.default.fileExists(atPath: lyricsFileURL(id).path)
        if let lyrics = meta.lyrics, !lyrics.isEmpty {
            try? lyrics.write(to: lyricsFileURL(id), atomically: true, encoding: .utf8)
            hasLyrics = true
        }

        return Track(
            id: id,
            relativePath: file.relativePath,
            title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist ?? "",
            album: meta.album ?? "",
            albumArtist: meta.albumArtist,
            genre: meta.genre,
            trackNumber: meta.trackNumber,
            discNumber: meta.discNumber,
            year: meta.year,
            duration: meta.duration,
            fileSize: file.size,
            modifiedAt: file.modified,
            dateAdded: previous?.dateAdded ?? Date(),
            hasArtwork: hasArtwork,
            hasLyrics: hasLyrics,
            artworkFetched: previous?.artworkFetched ?? false,
            lyricsFetched: previous?.lyricsFetched ?? false,
            playCount: previous?.playCount ?? 0,
            lastPlayed: previous?.lastPlayed
        )
    }

    nonisolated static func makeID(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func enumerateAudio(in root: URL) -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.resolvingSymlinksInPath().path
        var out: [FileEntry] = []
        while let url = enumerator.nextObject() as? URL {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            var path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath) { path.removeFirst(rootPath.count) }
            while path.hasPrefix("/") { path.removeFirst() }
            out.append(FileEntry(
                relativePath: path,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date()
            ))
        }
        return out
    }

    // MARK: - Import

    func importFiles(_ urls: [URL]) async {
        let fm = FileManager.default
        let dest = documentsURL.appendingPathComponent("Music", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let docsPath = documentsURL.resolvingSymlinksInPath().path

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let path = url.resolvingSymlinksInPath().path
            let inInbox = path.contains("/Inbox/")
            if path.hasPrefix(docsPath) && !inInbox { continue } // already in the library

            let target = uniqueURL(dest.appendingPathComponent(url.lastPathComponent))
            if inInbox {
                try? fm.moveItem(at: url, to: target)
            } else {
                try? fm.copyItem(at: url, to: target)
            }
        }
        // Clean up the system Inbox folder left behind by "Open in…"
        let inbox = documentsURL.appendingPathComponent("Inbox")
        if let left = try? fm.contentsOfDirectory(atPath: inbox.path), left.isEmpty {
            try? fm.removeItem(at: inbox)
        }
        await rescan()
        MetadataEnricher.shared.start()
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - Mutations

    private func mutate(_ id: String, _ change: (inout Track) -> Void) {
        guard let i = indexByID[id], tracks.indices.contains(i) else { return }
        change(&tracks[i])
    }

    func markPlayed(_ id: String) {
        mutate(id) { $0.playCount += 1; $0.lastPlayed = Date() }
        save()
    }

    func setArtwork(_ data: Data, for id: String, applyToAlbum: Bool) async {
        guard let jpeg = await Task.detached(priority: .utility, operation: { ImageUtil.normalizedJPEG(data) }).value,
              let track = track(id: id) else { return }
        var targets = [id]
        if applyToAlbum, track.hasKnownAlbum, let album = album(id: track.albumID) {
            targets += album.tracks.filter { !$0.hasArtwork && $0.id != id }.map(\.id)
        }
        for target in targets {
            try? jpeg.write(to: artworkFileURL(target), options: .atomic)
            ArtworkCache.shared.invalidate(target)
            SharedArtwork.invalidate(target)
            mutate(target) { $0.hasArtwork = true; $0.artworkFetched = true }
        }
        artworkRevision += 1
        save()
        PlayerEngine.shared.artworkDidChange(for: Set(targets))
    }

    func setLyrics(_ text: String, for id: String) {
        try? text.write(to: lyricsFileURL(id), atomically: true, encoding: .utf8)
        mutate(id) { $0.hasLyrics = true; $0.lyricsFetched = true }
        save()
    }

    func markFetched(_ id: String, artwork: Bool = false, lyrics: Bool = false) {
        mutate(id) {
            if artwork { $0.artworkFetched = true }
            if lyrics { $0.lyricsFetched = true }
        }
        save()
    }

    func resetFetchFlags(_ id: String, artwork: Bool, lyrics: Bool) {
        mutate(id) {
            if artwork { $0.artworkFetched = false }
            if lyrics { $0.lyricsFetched = false }
        }
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: url(for: track))
        try? FileManager.default.removeItem(at: artworkFileURL(track.id))
        try? FileManager.default.removeItem(at: lyricsFileURL(track.id))
        tracks.removeAll { $0.id == track.id }
        save()
    }
}
