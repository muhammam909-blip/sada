import Foundation
import Observation

/// Extra YouTube Music endpoints: radio (related songs) and charts.
enum YTMusic {
    private static func post(_ endpoint: String, _ extra: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250310.01.00", "hl": "en", "gl": "EG"]],
        ]
        for (k, v) in extra { body[k] = v }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineSearchError.badResponse
        }
        return json
    }

    /// "Song radio": songs similar to the given one (what YT Music plays after it).
    static func radio(videoID: String) async throws -> [OnlineSong] {
        let json = try await post("next", [
            "videoId": videoID,
            "playlistId": "RDAMVM\(videoID)",
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
        ])
        var renderers: [[String: Any]] = []
        YTMusicSearch.collect(json, key: "playlistPanelVideoRenderer", into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap(parsePanel).filter { seen.insert($0.id).inserted }
    }

    private static func texts(_ node: Any?) -> [String] {
        ((node as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
    }

    private static func parsePanel(_ r: [String: Any]) -> OnlineSong? {
        guard let id = r["videoId"] as? String, let title = texts(r["title"]).first else { return nil }
        var groups: [[String]] = [[]]
        for t in texts(r["longBylineText"]) {
            if t.trimmingCharacters(in: .whitespaces) == "•" { groups.append([]) } else { groups[groups.count - 1].append(t) }
        }
        let parts = groups.map { $0.joined().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let thumbs = ((r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let thumb = thumbs.last?["url"] as? String
        let hq = thumb.flatMap { s -> URL? in
            guard let range = s.range(of: #"=w\d+-h\d+.*$"#, options: .regularExpression) else { return URL(string: s) }
            return URL(string: s.replacingCharacters(in: range, with: "=w1200-h1200-l90-rj"))
        }
        return OnlineSong(
            id: id, title: title, artist: parts.first ?? "",
            album: parts.count > 1 && !parts[1].allSatisfy(\.isNumber) ? parts[1] : nil,
            durationText: texts(r["lengthText"]).first,
            thumbnailURL: thumb.flatMap(URL.init(string:)), artworkURL: hq
        )
    }

    /// Top songs chart for a country (YouTube Music Charts).
    static func charts(country: String) async throws -> [OnlineSong] {
        let json = try await post("browse", ["browseId": "FEmusic_charts", "formData": ["selectedValues": [country]]])
        var renderers: [[String: Any]] = []
        YTMusicSearch.collect(json, key: "musicResponsiveListItemRenderer", into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap(YTMusicSearch.parse).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Online home feed (Spotify / Anghami / YT Music style)

struct FeedSection: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let songs: [OnlineSong]
}

struct Genre: Identifiable, Hashable {
    let name: String
    let query: String
    let colors: [UInt32]
    let icon: String
    var id: String { name }

    static let all: [Genre] = [
        Genre(name: "Arabic Pop", query: "arabic pop hits", colors: [0xFF2D55, 0xFF9500], icon: "sparkles"),
        Genre(name: "Mahraganat", query: "مهرجانات", colors: [0xFF9500, 0xFFCC00], icon: "speaker.wave.3.fill"),
        Genre(name: "Tarab", query: "طرب أم كلثوم عبد الحليم", colors: [0xAF52DE, 0x5856D6], icon: "music.quarternote.3"),
        Genre(name: "Khaleeji", query: "اغاني خليجية", colors: [0x34C759, 0x30B0C7], icon: "sun.max.fill"),
        Genre(name: "Jazz", query: "jazz classics", colors: [0x5E5CE6, 0x0A84FF], icon: "music.note"),
        Genre(name: "Hip-Hop", query: "hip hop hits", colors: [0x1C1C1E, 0xFF3B30], icon: "flame.fill"),
        Genre(name: "Rock", query: "rock classics", colors: [0x8E8E93, 0x1C1C1E], icon: "bolt.fill"),
        Genre(name: "Lo-fi", query: "lofi chill beats", colors: [0x30B0C7, 0x5E5CE6], icon: "moon.stars.fill"),
        Genre(name: "Chill", query: "chill vibes songs", colors: [0x00C7BE, 0x34C759], icon: "leaf.fill"),
        Genre(name: "Workout", query: "workout motivation songs", colors: [0xFF3B30, 0xFF9500], icon: "figure.run"),
        Genre(name: "Romance", query: "اغاني رومانسية", colors: [0xFF2D55, 0xAF52DE], icon: "heart.fill"),
        Genre(name: "Classical", query: "classical music masterpieces", colors: [0xA2845E, 0x3A3A3C], icon: "pianokeys"),
    ]
}

@MainActor
@Observable
final class OnlineFeed {
    static let shared = OnlineFeed()

    private(set) var sections: [FeedSection] = []
    private(set) var loading = false
    private(set) var recentlyPlayed: [OnlineSong] = []

    private var lastLoad = Date.distantPast
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("online-feed.json")
    }
    private var searchCache: [String: [OnlineSong]] = [:]

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([FeedSection].self, from: data) {
            sections = cached // instant open; refreshed in the background
        }
        if let data = UserDefaults.standard.data(forKey: "online.recent"),
           let list = try? JSONDecoder().decode([OnlineSong].self, from: data) {
            recentlyPlayed = list
        }
    }

    func clearHistory() {
        recentlyPlayed = []
        UserDefaults.standard.removeObject(forKey: "online.recent")
    }

    func noteStreamed(_ song: OnlineSong) {
        recentlyPlayed.removeAll { $0.id == song.id }
        recentlyPlayed.insert(song, at: 0)
        recentlyPlayed = Array(recentlyPlayed.prefix(20))
        if let data = try? JSONEncoder().encode(recentlyPlayed) { UserDefaults.standard.set(data, forKey: "online.recent") }

        // Smart offline cache: a song you stream a few times is saved for offline listening.
        let d = UserDefaults.standard
        var counts = d.dictionary(forKey: "online.playCounts") as? [String: Int] ?? [:]
        counts[song.id, default: 0] += 1
        d.set(counts, forKey: "online.playCounts")
        let threshold = d.object(forKey: "online.autoCacheAfter") as? Int ?? 3
        if threshold > 0, counts[song.id, default: 0] >= threshold,
           !LibraryStore.shared.contains(title: song.title, artist: song.artist) {
            DownloadManager.shared.download(song)
        }
    }

    /// Cached search so going back and forth is instant.
    func search(_ query: String) async throws -> [OnlineSong] {
        let key = query.lowercased()
        if let hit = searchCache[key] { return hit }
        let result = try await YTMusicSearch.search(query)
        searchCache[key] = result
        return result
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard !loading, force || sections.isEmpty || Date().timeIntervalSince(lastLoad) > 3 * 3600 else { return }
        loading = true
        defer { loading = false }
        lastLoad = Date()

        let library = LibraryStore.shared
        let owned: (OnlineSong) -> Bool = { library.contains(title: $0.title, artist: $0.artist) }

        // Seeds = what you actually listen to: most played songs, else biggest artists.
        var seeds: [(title: String, artist: String)] = library.mostPlayed.prefix(6).map { ($0.title, $0.displayArtist) }
        if seeds.count < 3 {
            seeds += library.artists.sorted { $0.tracks.count > $1.tracks.count }.prefix(4).compactMap { a in
                a.tracks.first.map { ($0.title, a.name) }
            }
        }
        var seenArtists = Set<String>()
        seeds = seeds.filter { seenArtists.insert($0.artist.searchKey).inserted }

        var built: [FeedSection] = []

        let region = UserDefaults.standard.string(forKey: "online.region") ?? "EG"
        let regionName = OnlineSettingsView.regions.first { $0.code == region }?.name ?? region
        async let trending = (try? await YTMusic.charts(country: region)) ?? []
        async let fallbackTrending = (try? await YTMusicSearch.search("أحدث الأغاني المصرية")) ?? []

        // Matching your taste: radios of your top songs, mixed, without songs you already have.
        var radios: [(String, [OnlineSong])] = []
        await withTaskGroup(of: (String, [OnlineSong]).self) { group in
            for seed in seeds.prefix(4) {
                group.addTask {
                    guard let first = try? await YTMusicSearch.search("\(seed.artist) \(seed.title)").first,
                          let radio = try? await YTMusic.radio(videoID: first.id) else { return (seed.artist, []) }
                    return (seed.artist, radio)
                }
            }
            for await result in group where !result.1.isEmpty { radios.append(result) }
        }

        var mix: [OnlineSong] = []
        var mixIDs = Set<String>()
        let maxLen = radios.map(\.1.count).max() ?? 0
        for i in 1..<max(maxLen, 1) { // skip index 0 (the seed itself)
            for (_, songs) in radios where i < songs.count {
                let s = songs[i]
                if !owned(s), mixIDs.insert(s.id).inserted { mix.append(s) }
            }
            if mix.count >= 25 { break }
        }
        if !mix.isEmpty {
            built.append(FeedSection(id: "taste", title: "Matching Your Taste", subtitle: "Based on what you play most", songs: mix))
        }

        var trend = await trending
        if trend.isEmpty { trend = await fallbackTrending }
        if !trend.isEmpty {
            built.append(FeedSection(id: "trending-\(region)", title: "Trending in \(regionName)", subtitle: "Top songs this week", songs: Array(trend.prefix(30))))
        }

        for (artist, songs) in radios.prefix(3) {
            let fresh = songs.dropFirst().filter { !owned($0) }
            if fresh.count >= 4 {
                built.append(FeedSection(id: "because-\(artist)", title: "Because You Like \(artist)", subtitle: nil, songs: Array(fresh.prefix(20))))
            }
        }

        if !built.isEmpty {
            sections = built
            if let data = try? JSONEncoder().encode(built) { try? data.write(to: cacheURL, options: .atomic) }
        }
    }
}
