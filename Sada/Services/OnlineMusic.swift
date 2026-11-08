import AVFoundation
import Foundation
import Observation
import YouTubeKit

struct OnlineSong: Identifiable, Hashable {
    let id: String // YouTube video id
    let title: String
    let artist: String
    let album: String?
    let durationText: String?
    let thumbnailURL: URL?
    let artworkURL: URL?
}

/// Online songs travel through the player as normal `Track`s with this source id.
enum OnlineTrack {
    static let sourceID = "online"

    static func make(_ s: OnlineSong) -> Track {
        Track(
            id: "yt:\(s.id)", relativePath: s.id, title: s.title, artist: s.artist, album: s.album ?? "",
            albumArtist: nil, genre: nil, trackNumber: nil, discNumber: nil, year: nil,
            duration: DownloadManager.seconds(s.durationText), fileSize: 0, modifiedAt: Date(), dateAdded: Date(),
            hasArtwork: false, hasLyrics: false, artworkFetched: true, lyricsFetched: true, playCount: 0, lastPlayed: nil,
            sourceID: sourceID, favorite: nil, remoteArtwork: s.artworkURL?.absoluteString
        )
    }

    static func song(from t: Track) -> OnlineSong {
        OnlineSong(
            id: t.relativePath, title: t.title, artist: t.artist, album: t.album.isEmpty ? nil : t.album,
            durationText: t.duration > 0 ? formatTime(t.duration) : nil,
            thumbnailURL: t.remoteArtwork.flatMap(URL.init(string:)),
            artworkURL: t.remoteArtwork.flatMap(URL.init(string:))
        )
    }
}

/// Resolves and caches playable audio URLs for YouTube videos.
@MainActor
final class OnlineStreams {
    static let shared = OnlineStreams()
    private var cache: [String: (url: URL, at: Date)] = [:]
    private var inflight: [String: Task<URL?, Never>] = [:]

    func cachedURL(_ videoID: String) -> URL? {
        guard let hit = cache[videoID], Date().timeIntervalSince(hit.at) < 4 * 3600 else { return nil }
        return hit.url
    }

    func resolve(_ videoID: String) async -> URL? {
        if let url = cachedURL(videoID) { return url }
        if let task = inflight[videoID] { return await task.value }
        let task = Task<URL?, Never> {
            guard let streams = try? await YouTube(videoID: videoID).streams else { return nil }
            let audio = streams.filterAudioOnly()
            let stream = audio.filter { $0.fileExtension == .m4a }.highestAudioBitrateStream() ?? audio.highestAudioBitrateStream()
            return stream?.url
        }
        inflight[videoID] = task
        let url = await task.value
        inflight[videoID] = nil
        if let url { cache[videoID] = (url, Date()) }
        return url
    }
}

/// Search-as-you-type suggestions (same source YouTube uses).
enum SearchSuggestions {
    static func fetch(_ query: String) async -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1,
              let url = HTTP.url("https://suggestqueries.google.com/complete/search", ["client": "firefox", "ds": "yt", "q": q]),
              case let (data, 200)? = await HTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1, let list = json[1] as? [String]
        else { return [] }
        return Array(list.prefix(8))
    }
}

enum OnlineSearchError: LocalizedError {
    case badResponse
    var errorDescription: String? { "Search failed. Check your connection and try again." }
}

/// Searches YouTube Music's song catalogue (same results as the YT Music app's "Songs" filter).
enum YTMusicSearch {
    static func search(_ query: String) async throws -> [OnlineSong] {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250310.01.00", "hl": "en", "gl": "SA"]],
            "query": query,
            "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF", // filter: songs
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OnlineSearchError.badResponse }

        var renderers: [[String: Any]] = []
        collect(json, key: "musicResponsiveListItemRenderer", into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap(parse).filter { seen.insert($0.id).inserted }
    }

    private static func collect(_ node: Any, key: String, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let match = dict[key] as? [String: Any] { out.append(match); return }
            for value in dict.values { collect(value, key: key, into: &out) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, key: key, into: &out) }
        }
    }

    private static func runs(_ r: [String: Any], column: Int) -> [String] {
        guard let cols = r["flexColumns"] as? [[String: Any]], cols.indices.contains(column),
              let col = cols[column]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = col["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]] else { return [] }
        return runs.compactMap { $0["text"] as? String }
    }

    private static func parse(_ r: [String: Any]) -> OnlineSong? {
        var videoID = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String
        if videoID == nil {
            var endpoints: [[String: Any]] = []
            collect(r, key: "watchEndpoint", into: &endpoints)
            videoID = endpoints.compactMap { $0["videoId"] as? String }.first
        }
        guard let id = videoID, let title = runs(r, column: 0).first else { return nil }

        // Column 1 looks like: [Artist, " & ", Artist2, " • ", Album, " • ", "3:45"]
        var groups: [[String]] = [[]]
        for text in runs(r, column: 1) {
            if text.trimmingCharacters(in: .whitespaces) == "•" { groups.append([]) } else { groups[groups.count - 1].append(text) }
        }
        let parts = groups.map { $0.joined().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let isDuration: (String) -> Bool = { $0.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil }
        var fields = parts.filter { !["Song", "Video", "أغنية"].contains($0) }
        let duration = fields.last.flatMap { isDuration($0) ? $0 : nil }
        if duration != nil { fields.removeLast() }
        let artist = fields.first ?? ""
        let album = fields.count > 1 ? fields[1] : nil

        var thumbs: [[String: Any]] = []
        collect(r, key: "musicThumbnailRenderer", into: &thumbs)
        let thumbList = ((thumbs.first?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let thumbString = thumbList.last?["url"] as? String
        let thumb = thumbString.flatMap(URL.init(string:))
        let hq = thumbString.flatMap { s -> URL? in
            guard let range = s.range(of: #"=w\d+-h\d+.*$"#, options: .regularExpression) else { return URL(string: s) }
            return URL(string: s.replacingCharacters(in: range, with: "=w1200-h1200-l90-rj"))
        }
        return OnlineSong(id: id, title: title, artist: artist, album: album, durationText: duration,
                          thumbnailURL: thumb, artworkURL: hq)
    }
}

@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    enum State: Equatable {
        case preparing
        case downloading(Double)
        case finishing
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .downloading, .finishing: return true
            default: return false
            }
        }
    }

    private(set) var states: [String: State] = [:]

    private init() {}

    func download(_ song: OnlineSong) {
        if let s = states[song.id], s.isActive || s == .done { return }
        states[song.id] = .preparing
        Task { await run(song) }
    }

    private func run(_ song: OnlineSong) async {
        let library = LibraryStore.shared
        do {
            // 1. Best AAC audio stream (.m4a plays natively on iPhone).
            let streams = try await YouTube(videoID: song.id).streams
            let audio = streams.filterAudioOnly()
            guard let stream = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream()
                    ?? audio.highestAudioBitrateStream() else {
                states[song.id] = .failed("No audio stream")
                return
            }

            // 2. Download with progress.
            states[song.id] = .downloading(0)
            let id = song.id
            let temp = try await FileDownloader.download(stream.url) { progress in
                Task { @MainActor in DownloadManager.shared.states[id] = .downloading(progress) }
            }
            states[song.id] = .finishing

            // 3. Artwork + lyrics.
            var artwork: Data?
            if let url = song.artworkURL, case let (data, 200)? = await HTTP.get(url) { artwork = data }
            if artwork == nil, case .found(let data) = await ArtworkFetcher.fetch(title: song.title, artist: song.artist, album: song.album) {
                artwork = data
            }
            let durationSeconds = Self.seconds(song.durationText)
            var lyrics: String?
            if case .found(let text) = await LyricsFetcher.fetch(title: song.title, artist: song.artist, album: song.album, duration: durationSeconds) {
                lyrics = text
            }

            // 4. Write a tagged .m4a into the library.
            let folder = library.documentsURL.appendingPathComponent("Music/Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = Self.safeFileName("\(song.artist) - \(song.title)")
            let dest = library.uniqueURL(folder.appendingPathComponent(name).appendingPathExtension("m4a"))
            let jpeg = artwork.flatMap { ImageUtil.normalizedJPEG($0) }
            let tagged = await MetadataWriter.write(input: temp, output: dest, title: song.title, artist: song.artist,
                                                    album: song.album, artwork: jpeg, lyrics: lyrics)
            if !tagged { try FileManager.default.moveItem(at: temp, to: dest) } else { try? FileManager.default.removeItem(at: temp) }

            // 5. Add to the library and make sure artwork/lyrics are attached even if tagging failed.
            await library.rescan()
            let relative = "Music/Downloads/" + dest.lastPathComponent
            if let track = library.tracks.first(where: { $0.sourceID == nil && $0.relativePath == relative }) {
                if !track.hasArtwork, let jpeg { await library.setArtwork(jpeg, for: track.id, applyToAlbum: false) }
                if !track.hasLyrics, let lyrics { library.setLyrics(lyrics, for: track.id) }
            }
            states[song.id] = .done
        } catch {
            states[song.id] = .failed(error.localizedDescription)
        }
    }

    nonisolated static func seconds(_ text: String?) -> Double {
        guard let text else { return 0 }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    nonisolated static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(120)
            .description
    }
}

/// URLSession download with a progress callback.
enum FileDownloader {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            do {
                try FileManager.default.moveItem(at: location, to: temp)
                continuation?.resume(returning: temp)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
            session.finishTasksAndInvalidate()
        }
    }

    static func download(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Delegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }
}

/// Writes title/artist/album/artwork/lyrics into an .m4a (passthrough, no re-encoding).
enum MetadataWriter {
    static func write(input: URL, output: URL, title: String, artist: String, album: String?,
                      artwork: Data?, lyrics: String?) async -> Bool {
        let asset = AVURLAsset(url: input)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }

        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, type: String? = nil) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value
            i.extendedLanguageTag = "und"
            if let type { i.dataType = type }
            return i
        }
        var items = [
            item(.iTunesMetadataSongName, title as NSString),
            item(.iTunesMetadataArtist, artist as NSString),
        ]
        if let album, !album.isEmpty { items.append(item(.iTunesMetadataAlbum, album as NSString)) }
        if let lyrics { items.append(item(.iTunesMetadataLyrics, lyrics as NSString)) }
        if let artwork { items.append(item(.iTunesMetadataCoverArt, artwork as NSData, type: kCMMetadataBaseDataType_JPEG as String)) }
        export.metadata = items

        do {
            try await export.export(to: output, as: .m4a)
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            return false
        }
    }
}
