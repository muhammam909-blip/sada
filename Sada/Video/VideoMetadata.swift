import Foundation

/// Keyless metadata sources: TVmaze for series, Apple's iTunes catalogue for movies.
enum VideoMetadata {
    struct ShowInfo {
        let name: String
        let overview: String?
        let posterURL: URL?
        let backdropURL: URL?
        let genres: String?
        let rating: Double?
        let year: Int?
        let episodes: [String: EpisodeInfo] // "1x5"
    }

    struct EpisodeInfo {
        let name: String?
        let imageURL: URL?
        let runtime: Int?
    }

    struct MovieInfo {
        let title: String
        let overview: String?
        let posterURL: URL?
        var backdropURL: URL? = nil
        let genres: String?
        let year: Int?
        var rating: Double? = nil
    }

    /// Cinemeta (the catalogue Stremio/Nuvio use): sharp posters + backgrounds for movies and series, no key.
    static func cinemeta(type: String, title: String, year: Int?) async -> MovieInfo? {
        struct R: Decodable { let metas: [MetaPreview]? }
        let q = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(q).json"),
              case let (data, 200)? = await HTTP.get(url),
              let metas = try? JSONDecoder().decode(R.self, from: data).metas, !metas.isEmpty else { return nil }
        let key = TitleCleaner.cleanForMatching(title)
        func yearOf(_ m: MetaPreview) -> Int? { m.releaseInfo.flatMap { Int($0.prefix(4)) } }
        let named = metas.filter {
            let n = TitleCleaner.cleanForMatching($0.name)
            return n == key || n.contains(key) || key.contains(n)
        }
        let pick = named.first { m in year.map { y in yearOf(m).map { abs($0 - y) <= 1 } ?? true } ?? true } ?? named.first
        guard let m = pick else { return nil }
        return MovieInfo(title: m.name, overview: m.description, posterURL: m.poster.flatMap(URL.init(string:)),
                         backdropURL: m.background.flatMap(URL.init(string:)),
                         genres: m.genres?.prefix(3).joined(separator: ", "), year: yearOf(m),
                         rating: m.imdbRating.flatMap(Double.init))
    }

    private struct TVMShow: Decodable {
        let id: Int
        let name: String
        let premiered: String?
        let summary: String?
        let genres: [String]?
        let image: Img?
        let rating: Rating?
        let _embedded: Embedded?

        struct Img: Decodable { let medium: String?; let original: String? }
        struct Rating: Decodable { let average: Double? }
        struct Embedded: Decodable { let episodes: [Ep]? }
        struct Ep: Decodable {
            let season: Int
            let number: Int?
            let name: String?
            let runtime: Int?
            let image: Img?
        }
    }

    private struct TVMImage: Decodable {
        let type: String?
        let resolutions: Res
        struct Res: Decodable { let original: U? }
        struct U: Decodable { let url: String }
    }

    static func stripHTML(_ s: String?) -> String? {
        guard let s else { return nil }
        let out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func show(named name: String) async -> ShowInfo? {
        guard let url = HTTP.url("https://api.tvmaze.com/singlesearch/shows", ["q": name, "embed": "episodes"]),
              case let (data, 200)? = await HTTP.get(url),
              let show = try? JSONDecoder().decode(TVMShow.self, from: data)
        else { return await itunesShow(named: name) }

        var backdrop: URL?
        if let imgURL = URL(string: "https://api.tvmaze.com/shows/\(show.id)/images"),
           case let (imgData, 200)? = await HTTP.get(imgURL),
           let images = try? JSONDecoder().decode([TVMImage].self, from: imgData) {
            backdrop = images.first { $0.type == "background" }?.resolutions.original.flatMap { URL(string: $0.url) }
        }
        var episodes: [String: EpisodeInfo] = [:]
        for ep in show._embedded?.episodes ?? [] {
            guard let n = ep.number else { continue }
            episodes["\(ep.season)x\(n)"] = EpisodeInfo(
                name: ep.name, imageURL: (ep.image?.original ?? ep.image?.medium).flatMap(URL.init(string:)), runtime: ep.runtime)
        }
        return ShowInfo(
            name: show.name, overview: stripHTML(show.summary),
            posterURL: (show.image?.original ?? show.image?.medium).flatMap(URL.init(string:)),
            backdropURL: backdrop, genres: show.genres?.prefix(3).joined(separator: ", "),
            rating: show.rating?.average, year: show.premiered.flatMap { Int($0.prefix(4)) }, episodes: episodes)
    }

    private struct ITunes: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let trackName: String?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
            let longDescription: String?
            let shortDescription: String?
            let releaseDate: String?
            let primaryGenreName: String?
        }
    }

    private static func itunesShow(named name: String) async -> ShowInfo? {
        let country = name.containsArabic ? "eg" : "us"
        guard let url = HTTP.url("https://itunes.apple.com/search", ["term": name, "entity": "tvSeason", "limit": "1", "country": country]),
              case let (data, 200)? = await HTTP.get(url),
              let item = try? JSONDecoder().decode(ITunes.self, from: data).results.first else { return nil }
        return ShowInfo(
            name: item.artistName ?? name, overview: item.longDescription,
            posterURL: item.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "800x800bb")) },
            backdropURL: nil, genres: item.primaryGenreName, rating: nil,
            year: item.releaseDate.flatMap { Int($0.prefix(4)) }, episodes: [:])
    }

    static func movie(title: String, year: Int?) async -> MovieInfo? {
        if let c = await cinemeta(type: "movie", title: title, year: year), c.posterURL != nil { return c }
        let countries = title.containsArabic ? ["eg", "ae", "us"] : ["us", "eg"]
        for country in countries {
            guard let url = HTTP.url("https://itunes.apple.com/search", ["term": title, "entity": "movie", "limit": "10", "country": country]),
                  case let (data, 200)? = await HTTP.get(url),
                  let results = try? JSONDecoder().decode(ITunes.self, from: data).results, !results.isEmpty else { continue }
            let key = TitleCleaner.cleanForMatching(title)
            let best = results.first { item in
                let name = TitleCleaner.cleanForMatching(item.trackName ?? "")
                let sameYear = year == nil || item.releaseDate?.hasPrefix(String(year!)) == true
                return sameYear && (name == key || name.contains(key) || key.contains(name))
            } ?? results.first { TitleCleaner.cleanForMatching($0.trackName ?? "").contains(key) }
            guard let item = best else { continue }
            return MovieInfo(
                title: item.trackName ?? title,
                overview: item.longDescription ?? item.shortDescription,
                posterURL: item.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x900bb")) },
                genres: item.primaryGenreName,
                year: item.releaseDate.flatMap { Int($0.prefix(4)) })
        }
        return nil
    }
}
