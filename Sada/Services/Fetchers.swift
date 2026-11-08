import Foundation

enum FetchResult<T> {
    case found(T)
    case notFound
    case failed // network problem: try again later
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "MHM/0.2 (personal iOS music player)"]
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL) async -> (Data, Int)? {
        guard case let (data, response)? = try? await session.data(from: url) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func url(_ base: String, _ query: [String: String?]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        return c?.url
    }
}

// MARK: - Artwork (Deezer + iTunes)

enum ArtworkFetcher {
    private struct DeezerResponse: Decodable {
        let data: [Item]
        struct Item: Decodable {
            let title: String?
            let artist: Named?
            let album: AlbumInfo?
        }
        struct Named: Decodable { let name: String? }
        struct AlbumInfo: Decodable {
            let title: String?
            let cover_xl: String?
        }
    }

    private struct ITunesResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let artistName: String?
            let trackName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
    }

    static func fetch(title rawTitle: String, artist: String?, album: String?) async -> FetchResult<Data> {
        let title = TitleCleaner.clean(rawTitle)
        guard !title.isEmpty else { return .notFound }
        var anyFailure = false
        var best: (url: URL, score: Int)?

        func consider(_ result: FetchResult<(URL, Int)>) {
            switch result {
            case .found(let pair): if pair.1 > (best?.score ?? 0) { best = (pair.0, pair.1) }
            case .failed: anyFailure = true
            case .notFound: break
            }
        }

        consider(await deezer(title: title, artist: artist))
        if (best?.score ?? 0) < 5 {
            let arabic = (title + (artist ?? "")).containsArabic
            consider(await itunes(title: title, artist: artist, country: arabic ? "eg" : "us"))
            if (best?.score ?? 0) < 5, arabic {
                consider(await itunes(title: title, artist: artist, country: "sa"))
            }
        }

        if let best, case let (data, status)? = await HTTP.get(best.url), status == 200, !data.isEmpty {
            return .found(data)
        }
        return anyFailure ? .failed : .notFound
    }

    private static func deezer(title: String, artist: String?) async -> FetchResult<(URL, Int)> {
        let q: String
        if let artist, !artist.isEmpty {
            q = "artist:\"\(artist)\" track:\"\(title)\""
        } else {
            q = title
        }
        guard let url = HTTP.url("https://api.deezer.com/search", ["q": q, "limit": "10"]) else { return .notFound }
        guard case let (data, status)? = await HTTP.get(url) else { return .failed }
        guard status == 200, let res = try? JSONDecoder().decode(DeezerResponse.self, from: data) else {
            return status >= 500 ? .failed : .notFound
        }
        var best: (URL, Int)?
        for item in res.data {
            let score = Matcher.score(candidateTitle: item.title, candidateArtist: item.artist?.name, title: title, artist: artist)
            if score > (best?.1 ?? 0), let s = item.album?.cover_xl, let u = URL(string: s) { best = (u, score) }
        }
        // Retry without the strict artist filter (handles Arabic/Latin spelling differences).
        if best == nil, let artist, !artist.isEmpty {
            return await deezerLoose(title: title, artist: artist)
        }
        return best.map { .found($0) } ?? .notFound
    }

    private static func deezerLoose(title: String, artist: String) async -> FetchResult<(URL, Int)> {
        guard let url = HTTP.url("https://api.deezer.com/search", ["q": "\(artist) \(title)", "limit": "10"]) else { return .notFound }
        guard case let (data, status)? = await HTTP.get(url) else { return .failed }
        guard status == 200, let res = try? JSONDecoder().decode(DeezerResponse.self, from: data) else { return .notFound }
        var best: (URL, Int)?
        for item in res.data {
            let score = Matcher.score(candidateTitle: item.title, candidateArtist: item.artist?.name, title: title, artist: artist)
            if score > (best?.1 ?? 0), let s = item.album?.cover_xl, let u = URL(string: s) { best = (u, score) }
        }
        return best.map { .found($0) } ?? .notFound
    }

    private static func itunes(title: String, artist: String?, country: String) async -> FetchResult<(URL, Int)> {
        let term = [artist, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard let url = HTTP.url("https://itunes.apple.com/search", [
            "term": term, "entity": "song", "limit": "15", "country": country,
        ]) else { return .notFound }
        guard case let (data, status)? = await HTTP.get(url) else { return .failed }
        guard status == 200, let res = try? JSONDecoder().decode(ITunesResponse.self, from: data) else {
            return (status == 403 || status == 429 || status >= 500) ? .failed : .notFound
        }
        var best: (URL, Int)?
        for item in res.results {
            let score = Matcher.score(candidateTitle: item.trackName, candidateArtist: item.artistName, title: title, artist: artist)
            if score > (best?.1 ?? 0), let small = item.artworkUrl100,
               let u = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) {
                best = (u, score)
            }
        }
        return best.map { .found($0) } ?? .notFound
    }
}

// MARK: - Manual search candidates

struct ArtworkCandidate: Identifiable, Hashable {
    let id: String
    let thumbURL: URL
    let fullURL: URL
    let caption: String
}

extension ArtworkFetcher {
    /// Many results for the "Find Artwork" picker (Deezer + Apple Music).
    static func candidates(query: String) async -> [ArtworkCandidate] {
        var out: [ArtworkCandidate] = []
        var seen = Set<String>()

        struct DZ: Decodable {
            let data: [Item]
            struct Item: Decodable {
                let title: String?
                let artist: N?
                let album: A?
            }
            struct N: Decodable { let name: String? }
            struct A: Decodable { let title: String?; let cover_medium: String?; let cover_xl: String? }
        }
        if let url = HTTP.url("https://api.deezer.com/search", ["q": query, "limit": "25"]),
           case let (data, 200)? = await HTTP.get(url),
           let res = try? JSONDecoder().decode(DZ.self, from: data) {
            for item in res.data {
                guard let thumb = item.album?.cover_medium.flatMap(URL.init(string:)),
                      let full = item.album?.cover_xl.flatMap(URL.init(string:)),
                      seen.insert(full.absoluteString).inserted else { continue }
                out.append(ArtworkCandidate(id: full.absoluteString, thumbURL: thumb, fullURL: full,
                                            caption: "\(item.artist?.name ?? "") — \(item.album?.title ?? item.title ?? "")"))
            }
        }

        struct IT: Decodable {
            let results: [Item]
            struct Item: Decodable { let artistName: String?; let collectionName: String?; let artworkUrl100: String? }
        }
        let country = query.containsArabic ? "eg" : "us"
        if let url = HTTP.url("https://itunes.apple.com/search", ["term": query, "entity": "album", "limit": "25", "country": country]),
           case let (data, 200)? = await HTTP.get(url),
           let res = try? JSONDecoder().decode(IT.self, from: data) {
            for item in res.results {
                guard let small = item.artworkUrl100,
                      let thumb = URL(string: small.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
                      let full = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")),
                      seen.insert(full.absoluteString).inserted else { continue }
                out.append(ArtworkCandidate(id: full.absoluteString, thumbURL: thumb, fullURL: full,
                                            caption: "\(item.artistName ?? "") — \(item.collectionName ?? "")"))
            }
        }
        return out
    }
}

struct LyricsCandidate: Identifiable, Hashable {
    let id: Int
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    let synced: String?
    let plain: String?

    var text: String? { synced ?? plain }
}

extension LyricsFetcher {
    /// All matches for the "Find Lyrics" picker.
    static func search(title: String, artist: String) async -> [LyricsCandidate] {
        struct Item: Decodable {
            let id: Int
            let trackName: String?
            let artistName: String?
            let albumName: String?
            let duration: Double?
            let plainLyrics: String?
            let syncedLyrics: String?
        }
        var queries: [[String: String?]] = []
        if !artist.isEmpty { queries.append(["track_name": title, "artist_name": artist]) }
        queries.append(["q": "\(artist) \(title)".trimmingCharacters(in: .whitespaces)])
        queries.append(["track_name": title])

        var out: [LyricsCandidate] = []
        var seen = Set<Int>()
        for query in queries {
            guard let url = HTTP.url("https://lrclib.net/api/search", query),
                  case let (data, 200)? = await HTTP.get(url),
                  let items = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            for item in items where seen.insert(item.id).inserted {
                let synced = (item.syncedLyrics?.isEmpty ?? true) ? nil : item.syncedLyrics
                let plain = (item.plainLyrics?.isEmpty ?? true) ? nil : item.plainLyrics
                guard synced != nil || plain != nil else { continue }
                out.append(LyricsCandidate(id: item.id, title: item.trackName ?? "", artist: item.artistName ?? "",
                                           album: item.albumName, duration: item.duration, synced: synced, plain: plain))
            }
            if out.count >= 30 { break }
        }
        return out.sorted { ($0.synced != nil ? 0 : 1) < ($1.synced != nil ? 0 : 1) }
    }
}

// MARK: - Lyrics (LRCLIB)

enum LyricsFetcher {
    private struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var best: String? {
            if let s = syncedLyrics, !s.isEmpty { return s }
            if let p = plainLyrics, !p.isEmpty { return p }
            return nil
        }
    }

    static func fetch(title rawTitle: String, artist: String?, album: String?, duration: Double) async -> FetchResult<String> {
        let title = TitleCleaner.clean(rawTitle)
        guard !title.isEmpty else { return .notFound }
        var failed = false

        // 1. Exact lookup (needs artist + duration)
        if let artist, !artist.isEmpty, duration > 0,
           let url = HTTP.url("https://lrclib.net/api/get", [
               "track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded())),
           ]) {
            if case let (data, status)? = await HTTP.get(url) {
                if status == 200, let item = try? JSONDecoder().decode(Item.self, from: data), let text = item.best {
                    return .found(text)
                }
            } else {
                failed = true
            }
        }

        // 2. Search by fields, then free text
        var queries: [[String: String?]] = []
        if let artist, !artist.isEmpty { queries.append(["track_name": title, "artist_name": artist]) }
        queries.append(["q": [artist, title].compactMap { $0 }.joined(separator: " ")])
        if artist != nil { queries.append(["track_name": title]) }

        for query in queries {
            guard let url = HTTP.url("https://lrclib.net/api/search", query) else { continue }
            guard case let (data, status)? = await HTTP.get(url) else { failed = true; continue }
            guard status == 200, let items = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            if let pick = choose(items, title: title, artist: artist, duration: duration) { return .found(pick) }
        }
        return failed ? .failed : .notFound
    }

    private static func choose(_ items: [Item], title: String, artist: String?, duration: Double) -> String? {
        var best: (String, Int)?
        for item in items where item.instrumental != true {
            guard let text = item.best else { continue }
            var score = Matcher.score(candidateTitle: item.trackName, candidateArtist: item.artistName, title: title, artist: artist)
            guard score > 0 else { continue }
            if duration > 0, let d = item.duration {
                let diff = abs(d - duration)
                if diff > 8 { continue }
                if diff < 2 { score += 2 }
            }
            if item.syncedLyrics?.isEmpty == false { score += 2 }
            if score > (best?.1 ?? 0) { best = (text, score) }
        }
        return best?.0
    }
}
