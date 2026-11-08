import CryptoKit
import Foundation
import Observation
import UIKit

struct FileEntry: Sendable {
    let sourceID: String?
    let relativePath: String
    let size: Int64
    let modified: Date

    var key: String { "\(sourceID ?? "")|\(relativePath)" }
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()
    static let schemaVersion = 2

    private(set) var tracks: [Track] = [] {
        didSet { rebuildIndexes() }
    }
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var linkedFolders: [LinkedFolder] = []
    private(set) var isScanning = false
    /// Bumped whenever artwork changes so views reload images.
    private(set) var artworkRevision = 0
    var enrichmentStatus: String?
    var importStatus: String?

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
    @ObservationIgnored private var resolvedFolders: [String: URL] = [:]

    private var libraryFile: URL { supportURL.appendingPathComponent("library.json") }
    private var playlistsFile: URL { supportURL.appendingPathComponent("playlists.json") }
    private var foldersFile: URL { supportURL.appendingPathComponent("folders.json") }

    var favorites: [Track] { tracks.filter(\.isFavorite) }

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
    func playlist(id: String) -> Playlist? { playlists.first { $0.id == id } }
    func tracks(in playlist: Playlist) -> [Track] { playlist.trackIDs.compactMap { track(id: $0) } }

    func rootURL(for sourceID: String?) -> URL? {
        guard let sourceID else { return documentsURL }
        return resolvedFolders[sourceID]
    }

    func url(for track: Track) -> URL {
        (rootURL(for: track.sourceID) ?? documentsURL).appendingPathComponent(track.relativePath)
    }

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

    /// True if a song with this title/artist is already in the library (used by online search).
    func contains(title: String, artist: String) -> Bool {
        let t = TitleCleaner.cleanForMatching(title)
        let a = TitleCleaner.cleanForMatching(artist)
        return tracks.contains {
            TitleCleaner.cleanForMatching($0.title) == t
                && (a.isEmpty || TitleCleaner.cleanForMatching($0.displayArtist).contains(a)
                    || a.contains(TitleCleaner.cleanForMatching($0.displayArtist)))
        }
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: foldersFile),
           let folders = try? decoder.decode([LinkedFolder].self, from: data) {
            linkedFolders = folders
            for folder in folders { resolve(folder) }
        }
        if let data = try? Data(contentsOf: playlistsFile),
           let lists = try? decoder.decode([Playlist].self, from: data) {
            playlists = lists
        }
        if let data = try? Data(contentsOf: libraryFile),
           let decoded = try? decoder.decode([Track].self, from: data) {
            tracks = decoded
        }
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

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: playlistsFile, options: .atomic) }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(linkedFolders) { try? data.write(to: foldersFile, options: .atomic) }
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

        let albumsByArtist = Dictionary(grouping: albums) { $0.artist.searchKey }
        let byArtist = Dictionary(grouping: tracks) { $0.albumArtistName.searchKey }
        artists = byArtist.map { key, items in
            Artist(
                id: key,
                name: items[0].albumArtistName,
                tracks: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                albums: albumsByArtist[key] ?? []
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Linked folders

    private func resolve(_ folder: LinkedFolder) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource() // kept open for the app's lifetime
        resolvedFolders[folder.id] = url
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
           let i = linkedFolders.firstIndex(where: { $0.id == folder.id }) {
            linkedFolders[i].bookmark = fresh
            saveFolders()
        }
    }

    func isFolderAvailable(_ folder: LinkedFolder) -> Bool { resolvedFolders[folder.id] != nil }

    /// Reads a folder from another app in place (no copy, no extra storage).
    func linkFolder(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            importStatus = "Couldn't open that folder."
            return
        }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            url.stopAccessingSecurityScopedResource()
            importStatus = "Couldn't remember that folder."
            return
        }
        let folder = LinkedFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmark: bookmark)
        linkedFolders.append(folder)
        resolvedFolders[folder.id] = url
        saveFolders()
        importStatus = "Reading \(folder.name)…"
        await rescan()
        importStatus = nil
        MetadataEnricher.shared.start()
    }

    func unlinkFolder(_ folder: LinkedFolder) {
        resolvedFolders[folder.id]?.stopAccessingSecurityScopedResource()
        resolvedFolders[folder.id] = nil
        linkedFolders.removeAll { $0.id == folder.id }
        saveFolders()
        let removed = Set(tracks.filter { $0.sourceID == folder.id }.map(\.id))
        tracks.removeAll { removed.contains($0.id) }
        removeFromPlaylists(removed)
        save()
    }

    // MARK: - Scanning

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        migrateIfNeeded()
        await rescan()
        MetadataEnricher.shared.start()
    }

    /// New metadata rules (folder names → artist/album) need one full re-read.
    private func migrateIfNeeded() {
        let d = UserDefaults.standard
        guard d.integer(forKey: "librarySchema") < Self.schemaVersion else { return }
        var copy = tracks
        for i in copy.indices {
            copy[i].modifiedAt = .distantPast
            if !copy[i].hasArtwork { copy[i].artworkFetched = false }
            if !copy[i].hasLyrics { copy[i].lyricsFetched = false }
        }
        tracks = copy
        d.set(Self.schemaVersion, forKey: "librarySchema")
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

        var sources: [(String?, URL)] = [(nil, documentsURL)]
        for folder in linkedFolders {
            if let url = resolvedFolders[folder.id] { sources.append((folder.id, url)) }
        }
        let unavailable = Set(linkedFolders.map(\.id)).subtracting(resolvedFolders.keys)
        let roots = sources
        let files = await Task.detached(priority: .utility) {
            roots.flatMap { LibraryStore.enumerateAudio(in: $0.1, sourceID: $0.0) }
        }.value

        let existing = Dictionary(tracks.map { ("\($0.sourceID ?? "")|\($0.relativePath)", $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Track] = []
        result.reserveCapacity(files.count)
        // Keep songs from folders that are temporarily unreachable.
        result += tracks.filter { $0.sourceID.map(unavailable.contains) ?? false }
        var changed = false
        var newSinceFlush = 0

        for file in files {
            if let old = existing[file.key], old.fileSize == file.size,
               abs(old.modifiedAt.timeIntervalSince(file.modified)) < 1 {
                result.append(old)
                continue
            }
            changed = true
            let track = await makeTrack(file, previous: existing[file.key])
            result.append(track)
            newSinceFlush += 1
            if newSinceFlush >= 40 {
                newSinceFlush = 0
                importStatus = "Adding songs… \(result.count)"
                tracks = merged(result, keeping: tracks)
            }
        }
        if result.count != tracks.count { changed = true }

        if changed {
            tracks = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            save()
        }
        if importStatus?.hasPrefix("Adding songs") == true { importStatus = nil }
    }

    private func merged(_ scanned: [Track], keeping old: [Track]) -> [Track] {
        let ids = Set(scanned.map(\.id))
        return (scanned + old.filter { !ids.contains($0.id) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func makeTrack(_ file: FileEntry, previous: Track?) async -> Track {
        let root = rootURL(for: file.sourceID) ?? documentsURL
        let url = root.appendingPathComponent(file.relativePath)
        let meta = await MetadataReader.read(url: url)
        let id = previous?.id ?? Self.makeID(file.sourceID.map { "\($0)|\(file.relativePath)" } ?? file.relativePath)
        let folderGuess = Self.inferFromFolders(file.relativePath)

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
        if let lyrics = meta.lyrics, !lyrics.isEmpty, !(previous?.hasLyrics ?? false) {
            try? lyrics.write(to: lyricsFileURL(id), atomically: true, encoding: .utf8)
            hasLyrics = true
        }

        return Track(
            id: id,
            relativePath: file.relativePath,
            title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist ?? folderGuess.artist ?? "",
            album: meta.album ?? folderGuess.album ?? "",
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
            lastPlayed: previous?.lastPlayed,
            sourceID: file.sourceID,
            favorite: previous?.favorite
        )
    }

    /// "Adele - 21/song.mp3" → (Adele, 21); "Abdel Halim/song.mp3" → (Abdel Halim, nil);
    /// "Cairokee/Album/song.mp3" → (Cairokee, Album). Used only when tags are missing.
    nonisolated static func inferFromFolders(_ relativePath: String) -> (artist: String?, album: String?) {
        let generic: Set<String> = [
            "music", "imported", "downloads", "download", "inbox", "songs", "audio", "mp3", "media",
            "arabic", "english", "downloader music", "my music", "موسيقى", "اغاني", "أغاني", "عربي",
        ]
        let folders = relativePath.split(separator: "/").dropLast().map(String.init)
            .filter { !generic.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }
        guard let last = folders.last else { return (nil, nil) }
        let parts = last.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, !parts[0].isEmpty {
            return (parts[0], parts.dropFirst().joined(separator: " - "))
        }
        if folders.count >= 2 { return (folders[folders.count - 2], last) }
        return (last, nil)
    }

    nonisolated static func makeID(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func enumerateAudio(in root: URL, sourceID: String?) -> [FileEntry] {
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
                sourceID: sourceID,
                relativePath: path,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date()
            ))
        }
        return out
    }

    // MARK: - Import (copy)

    /// Copies files and/or whole folders (with subfolders) into the app.
    func importFiles(_ urls: [URL]) async {
        let fm = FileManager.default
        let dest = documentsURL.appendingPathComponent("Music", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let docsPath = documentsURL.resolvingSymlinksInPath().path

        // Build the list of (source, target) pairs first.
        var jobs: [(URL, URL)] = []
        var scoped: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            let path = url.resolvingSymlinksInPath().path
            let inInbox = path.contains("/Inbox/")
            if path.hasPrefix(docsPath) && !inInbox { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let folderTarget = uniqueURL(dest.appendingPathComponent(url.lastPathComponent, isDirectory: true))
                for entry in Self.enumerateAudio(in: url, sourceID: nil) {
                    jobs.append((url.appendingPathComponent(entry.relativePath),
                                 folderTarget.appendingPathComponent(entry.relativePath)))
                }
            } else {
                jobs.append((url, uniqueURL(dest.appendingPathComponent(url.lastPathComponent))))
            }
        }

        for (n, job) in jobs.enumerated() {
            importStatus = "Copying \(n + 1) of \(jobs.count)…"
            let (from, to) = job
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if from.path.contains("/Inbox/") {
                    try? fm.moveItem(at: from, to: to)
                } else {
                    try? fm.copyItem(at: from, to: to)
                }
            }.value
        }
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }

        let inbox = documentsURL.appendingPathComponent("Inbox")
        if let left = try? fm.contentsOfDirectory(atPath: inbox.path), left.isEmpty {
            try? fm.removeItem(at: inbox)
        }
        importStatus = jobs.isEmpty ? nil : "Reading \(jobs.count) songs…"
        await rescan()
        importStatus = nil
        MetadataEnricher.shared.start()
    }

    func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
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

    func toggleFavorite(_ id: String) {
        mutate(id) { $0.favorite = !($0.favorite ?? false) }
        save()
        PlayerEngine.shared.trackInfoDidChange(id)
    }

    func updateInfo(_ id: String, title: String, artist: String, album: String) {
        mutate(id) {
            $0.title = title.trimmingCharacters(in: .whitespaces)
            $0.artist = artist.trimmingCharacters(in: .whitespaces)
            $0.album = album.trimmingCharacters(in: .whitespaces)
            if !$0.hasArtwork { $0.artworkFetched = false }
            if !$0.hasLyrics { $0.lyricsFetched = false }
        }
        save()
        PlayerEngine.shared.trackInfoDidChange(id)
        MetadataEnricher.shared.start()
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
        PlayerEngine.shared.lyricsDidChange(for: id)
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

    /// Clears "not found" flags for every song still missing artwork or lyrics, then searches again.
    func retryMissing() {
        var copy = tracks
        for i in copy.indices {
            if !copy[i].hasArtwork { copy[i].artworkFetched = false }
            if !copy[i].hasLyrics { copy[i].lyricsFetched = false }
        }
        tracks = copy
        save()
        MetadataEnricher.shared.start()
    }

    /// Deletes the audio file itself (also from a linked folder) and everything cached for it.
    func delete(_ track: Track) {
        PlayerEngine.shared.removeEverywhere(track.id)
        try? FileManager.default.removeItem(at: url(for: track))
        try? FileManager.default.removeItem(at: artworkFileURL(track.id))
        try? FileManager.default.removeItem(at: lyricsFileURL(track.id))
        SharedArtwork.invalidate(track.id)
        tracks.removeAll { $0.id == track.id }
        removeFromPlaylists([track.id])
        save()
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String, with trackIDs: [String] = []) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let playlist = Playlist(id: UUID().uuidString, name: clean.isEmpty ? "New Playlist" : clean,
                                trackIDs: trackIDs, createdAt: Date())
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    func add(_ trackID: String, to playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.append(trackID)
        savePlaylists()
    }

    func removeFromPlaylist(_ playlistID: String, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        savePlaylists()
    }

    func movePlaylistItems(_ playlistID: String, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    func renamePlaylist(_ playlistID: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].name = name
        savePlaylists()
    }

    func deletePlaylist(_ playlistID: String) {
        playlists.removeAll { $0.id == playlistID }
        savePlaylists()
    }

    private func removeFromPlaylists(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        savePlaylists()
    }
}
