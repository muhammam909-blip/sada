import Foundation

enum VideoKind: String, Codable {
    case movie, episode
}

struct VideoItem: Identifiable, Codable, Hashable {
    var id: String
    var sourceID: String?
    var relativePath: String
    var fileSize: Int64
    var modifiedAt: Date
    var dateAdded: Date

    // Parsed from the file name
    var kind: VideoKind
    var title: String
    var showName: String?
    var season: Int?
    var episode: Int?
    var year: Int?

    // Online metadata (TVmaze / iTunes)
    var posterFile: String?
    var backdropFile: String?
    var stillFile: String?
    var overview: String?
    var episodeTitle: String?
    var rating: Double?
    var genres: String?
    var metaFetched: Bool

    // Playback
    var position: Double
    var duration: Double
    var lastWatched: Date?
    var watched: Bool

    var fileName: String { (relativePath as NSString).lastPathComponent }
    var showKey: String { (showName ?? title).searchKey }
    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    var isInProgress: Bool { !watched && position > 20 && progress < 0.92 }

    var displayTitle: String {
        switch kind {
        case .movie: return title
        case .episode:
            if let episodeTitle, !episodeTitle.isEmpty { return episodeTitle }
            return "Episode \(episode ?? 0)"
        }
    }

    var episodeCode: String? {
        guard kind == .episode else { return nil }
        return String(format: "S%02dE%02d", season ?? 1, episode ?? 0)
    }
}

struct VideoShow: Identifiable, Hashable {
    let id: String
    let name: String
    let episodes: [VideoItem]

    var posterFile: String? { episodes.lazy.compactMap(\.posterFile).first }
    var backdropFile: String? { episodes.lazy.compactMap(\.backdropFile).first }
    var overview: String? { episodes.lazy.compactMap(\.overview).first }
    var seasons: [Int] { Array(Set(episodes.map { $0.season ?? 1 })).sorted() }
    var year: Int? { episodes.compactMap(\.year).min() }
    var genres: String? { episodes.lazy.compactMap(\.genres).first }
    var rating: Double? { episodes.lazy.compactMap(\.rating).first }
    var unwatchedCount: Int { episodes.filter { !$0.watched }.count }

    /// The episode to play when you tap "Play": the one in progress, else the first unwatched.
    var nextUp: VideoItem? {
        episodes.filter(\.isInProgress).max { ($0.lastWatched ?? .distantPast) < ($1.lastWatched ?? .distantPast) }
            ?? episodes.first { !$0.watched }
            ?? episodes.first
    }
}

/// Turns "Breaking.Bad.S02E05.1080p.WEB-DL.mkv" into show/season/episode,
/// and "Inception.2010.1080p.BluRay.x264.mp4" into title/year.
enum VideoNameParser {
    struct Result {
        var kind: VideoKind
        var title: String
        var showName: String?
        var season: Int?
        var episode: Int?
        var year: Int?
    }

    private static let junk = try! NSRegularExpression(
        pattern: #"\b(2160p|1080p|720p|480p|4k|uhd|hdr10?|dv|bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|web|hdtv|hdrip|dvdrip|x264|x265|h\.?264|h\.?265|hevc|avc|aac|ac3|eac3|dts|ddp?5\.1|atmos|10bit|8bit|yify|yts|rarbg|extended|remastered|proper|repack|dual|multi|subbed|dubbed|nf|amzn|dsnp|hmax|shahid|watch|arabic|مترجم|مدبلج)\b.*$"#,
        options: [.caseInsensitive])
    private static let seasonEpisode = try! NSRegularExpression(pattern: #"[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})"#)
    private static let xFormat = try! NSRegularExpression(pattern: #"\b(\d{1,2})x(\d{2,3})\b"#)
    private static let episodeOnly = try! NSRegularExpression(
        pattern: #"(?:\b(?:ep|episode|e)[ ._-]*|الحلقة[ ._-]*|حلقة[ ._-]*)(\d{1,4})"#, options: [.caseInsensitive])
    private static let seasonWord = try! NSRegularExpression(
        pattern: #"(?:\bseason|\bs|الموسم|موسم)[ ._-]*(\d{1,2})"#, options: [.caseInsensitive])
    private static let yearRegex = try! NSRegularExpression(pattern: #"[\(\[ ._-]((?:19|20)\d{2})(?:[\)\] ._-]|$)"#)

    static func parse(fileName: String, folders: [String]) -> Result {
        let base = (fileName as NSString).deletingPathExtension
        let spaced = base.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let ns = spaced as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Episode patterns
        if let m = seasonEpisode.firstMatch(in: spaced, range: full) ?? xFormat.firstMatch(in: spaced, range: full) {
            let season = Int(ns.substring(with: m.range(at: 1)))
            let episode = Int(ns.substring(with: m.range(at: 2)))
            var show = clean(ns.substring(to: m.range.location))
            if show.isEmpty { show = showFromFolders(folders) }
            return Result(kind: .episode, title: show, showName: show, season: season, episode: episode, year: year(in: spaced))
        }
        if let m = episodeOnly.firstMatch(in: spaced, range: full) {
            let episode = Int(ns.substring(with: m.range(at: 1)))
            var show = clean(ns.substring(to: m.range.location))
            var season = seasonFromFolders(folders) ?? 1
            if let s = seasonWord.firstMatch(in: show, range: NSRange(location: 0, length: (show as NSString).length)) {
                season = Int((show as NSString).substring(with: s.range(at: 1))) ?? season
                show = clean((show as NSString).substring(to: s.range.location))
            }
            if show.isEmpty { show = showFromFolders(folders) }
            if !show.isEmpty {
                return Result(kind: .episode, title: show, showName: show, season: season, episode: episode, year: nil)
            }
        }

        // Movie
        let y = year(in: spaced)
        var title = spaced
        if let ym = yearRegex.firstMatch(in: spaced, range: full) {
            title = ns.substring(to: ym.range.location)
        }
        title = clean(title)
        if title.isEmpty { title = base }
        return Result(kind: .movie, title: title, showName: nil, season: nil, episode: nil, year: y)
    }

    static func clean(_ s: String) -> String {
        var out = junk.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        out = out.replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[-–_]+\s*$"#, with: "", options: .regularExpression)
        return out.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–."))
    }

    private static func year(in s: String) -> Int? {
        let ns = s as NSString
        guard let m = yearRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private static func showFromFolders(_ folders: [String]) -> String {
        for folder in folders.reversed() {
            let lower = folder.lowercased()
            if lower.hasPrefix("season") || lower.hasPrefix("s0") || folder.hasPrefix("الموسم") || folder.hasPrefix("موسم") { continue }
            if ["videos", "movies", "series", "tv", "shows", "مسلسلات", "افلام", "أفلام"].contains(lower) { continue }
            let cleaned = clean(folder.replacingOccurrences(of: ".", with: " "))
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    private static func seasonFromFolders(_ folders: [String]) -> Int? {
        for folder in folders.reversed() {
            let ns = folder as NSString
            if let m = seasonWord.firstMatch(in: folder, range: NSRange(location: 0, length: ns.length)) {
                return Int(ns.substring(with: m.range(at: 1)))
            }
        }
        return nil
    }
}
