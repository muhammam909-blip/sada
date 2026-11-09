import Foundation
import Observation
import YouTubeKit

// MARK: - Stremio addon protocol (same addons Nuvio / Stremio use)

struct AddonManifest: Codable, Hashable, Identifiable {
    struct Catalog: Codable, Hashable {
        let type: String
        let id: String
        let name: String?
        let extra: [Extra]?
        let extraRequired: [String]?

        struct Extra: Codable, Hashable {
            let name: String
            let isRequired: Bool?
        }

        var supportsSearch: Bool { extra?.contains { $0.name == "search" } ?? false }
        var needsExtra: Bool {
            (extraRequired?.isEmpty == false) || (extra?.contains { $0.isRequired == true } ?? false)
        }
    }

    enum Resource: Codable, Hashable {
        case name(String)
        case full(name: String, types: [String]?, idPrefixes: [String]?)

        var name: String {
            switch self {
            case .name(let n): n
            case .full(let n, _, _): n
            }
        }

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(s)
                return
            }
            struct Full: Decodable { let name: String; let types: [String]?; let idPrefixes: [String]? }
            let f = try Full(from: decoder)
            self = .full(name: f.name, types: f.types, idPrefixes: f.idPrefixes)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(name)
        }
    }

    let id: String
    let name: String
    let version: String?
    let description: String?
    let resources: [Resource]
    let types: [String]?
    let catalogs: [Catalog]?
    let idPrefixes: [String]?
    var baseURL: String = ""

    enum CodingKeys: String, CodingKey { case id, name, version, description, resources, types, catalogs, idPrefixes, baseURL }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try? c.decode(String.self, forKey: .version)
        description = try? c.decode(String.self, forKey: .description)
        resources = (try? c.decode([Resource].self, forKey: .resources)) ?? []
        types = try? c.decode([String].self, forKey: .types)
        catalogs = try? c.decode([Catalog].self, forKey: .catalogs)
        idPrefixes = try? c.decode([String].self, forKey: .idPrefixes)
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
    }

    func provides(_ resource: String) -> Bool { resources.contains { $0.name == resource } }
}

struct MetaPreview: Codable, Hashable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
}

struct MetaDetail: Codable, Hashable {
    struct Video: Codable, Hashable, Identifiable {
        let id: String
        let title: String?
        let name: String?
        let season: Int?
        let episode: Int?
        let thumbnail: String?
        let overview: String?
        let released: String?
        var displayTitle: String { title ?? name ?? "Episode \(episode ?? 0)" }
    }

    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let imdbRating: String?
    let genres: [String]?
    let cast: [String]?
    let videos: [Video]?
}

struct StreamOption: Identifiable, Hashable {
    let id = UUID()
    let addon: String
    let title: String
    let subtitle: String?
    let url: URL?
    let ytId: String?
    let isTorrent: Bool
    let headers: [String: String]

    var playable: Bool { url != nil || ytId != nil }
}

enum StremioClient {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasPrefix("http") { s = "https://" + s }
        if !s.hasSuffix("manifest.json") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json" }
        return s
    }

    static func manifest(from raw: String) async throws -> AddonManifest {
        let urlString = normalize(raw)
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var m = try JSONDecoder().decode(AddonManifest.self, from: data)
        m.baseURL = String(urlString.dropLast("/manifest.json".count))
        return m
    }

    private static func get<T: Decodable>(_ base: String, _ path: String, as: T.Type) async -> T? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: base + "/" + encoded),
              case let (data, 200)? = await HTTP.get(url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func catalog(_ addon: AddonManifest, _ catalog: AddonManifest.Catalog, search: String? = nil) async -> [MetaPreview] {
        struct R: Decodable { let metas: [MetaPreview]? }
        let path = search.map { "catalog/\(catalog.type)/\(catalog.id)/search=\($0).json" } ?? "catalog/\(catalog.type)/\(catalog.id).json"
        return await get(addon.baseURL, path, as: R.self)?.metas ?? []
    }

    static func meta(_ addon: AddonManifest, type: String, id: String) async -> MetaDetail? {
        struct R: Decodable { let meta: MetaDetail? }
        return await get(addon.baseURL, "meta/\(type)/\(id).json", as: R.self)?.meta
    }

    static func streams(_ addon: AddonManifest, type: String, id: String) async -> [StreamOption] {
        struct R: Decodable { let streams: [S]? }
        struct S: Decodable {
            let name: String?
            let title: String?
            let description: String?
            let url: String?
            let ytId: String?
            let infoHash: String?
            let behaviorHints: Hints?
            struct Hints: Decodable {
                let proxyHeaders: Proxy?
                struct Proxy: Decodable { let request: [String: String]? }
            }
        }
        let list = await get(addon.baseURL, "stream/\(type)/\(id).json", as: R.self)?.streams ?? []
        return list.map { s in
            let url = s.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            return StreamOption(
                addon: addon.name,
                title: (s.name ?? addon.name).replacingOccurrences(of: "\n", with: " "),
                subtitle: (s.title ?? s.description)?.replacingOccurrences(of: "\n", with: " · "),
                url: url, ytId: s.ytId, isTorrent: s.infoHash != nil && url == nil,
                headers: s.behaviorHints?.proxyHeaders?.request ?? [:])
        }
    }

    /// Plays a YouTube stream source (video + audio in one file).
    static func youtubeURL(_ id: String) async -> URL? {
        guard let streams = try? await YouTube(videoID: id).streams else { return nil }
        return streams.filterVideoAndAudio().highestResolutionStream()?.url
    }
}

@MainActor
@Observable
final class AddonStore {
    static let shared = AddonStore()
    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    private(set) var addons: [AddonManifest] = []
    private(set) var loading = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "addons.v1"),
           let list = try? JSONDecoder().decode([AddonManifest].self, from: data) {
            addons = list
        }
    }

    var catalogAddons: [AddonManifest] { addons.filter { $0.provides("catalog") } }
    var streamAddons: [AddonManifest] { addons.filter { $0.provides("stream") } }
    var metaAddon: AddonManifest? { addons.first { $0.provides("meta") } }

    private func save() {
        if let data = try? JSONEncoder().encode(addons) { UserDefaults.standard.set(data, forKey: "addons.v1") }
    }

    /// Cinemeta is added on first use for posters, catalogs and episode lists.
    func ensureDefaults() async {
        guard addons.isEmpty, !UserDefaults.standard.bool(forKey: "addons.defaultsAdded") else { return }
        UserDefaults.standard.set(true, forKey: "addons.defaultsAdded")
        try? await add(Self.cinemeta)
    }

    func add(_ raw: String) async throws {
        loading = true
        defer { loading = false }
        let m = try await StremioClient.manifest(from: raw)
        addons.removeAll { $0.baseURL == m.baseURL }
        addons.append(m)
        save()
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
        save()
    }

    func move(from: IndexSet, to: Int) {
        addons.move(fromOffsets: from, toOffset: to)
        save()
    }

    func meta(type: String, id: String) async -> MetaDetail? {
        for addon in addons where addon.provides("meta") {
            if let m = await StremioClient.meta(addon, type: type, id: id) { return m }
        }
        return nil
    }

    func streams(type: String, id: String) async -> [StreamOption] {
        await withTaskGroup(of: [StreamOption].self) { group in
            for addon in streamAddons {
                group.addTask { await StremioClient.streams(addon, type: type, id: id) }
            }
            var all: [StreamOption] = []
            for await list in group { all += list }
            return all.sorted { ($0.playable ? 0 : 1) < ($1.playable ? 0 : 1) }
        }
    }
}

extension VideoItem {
    /// A streamed (not downloaded) movie or episode.
    static func remote(url: URL, title: String, kind: VideoKind, show: String? = nil, season: Int? = nil, episode: Int? = nil,
                       episodeTitle: String? = nil) -> VideoItem {
        VideoItem(
            id: LibraryStore.makeID("remote|" + url.absoluteString), sourceID: "remote", relativePath: url.absoluteString,
            fileSize: 0, modifiedAt: Date(), dateAdded: Date(), kind: kind, title: title, showName: show,
            season: season, episode: episode, year: nil, posterFile: nil, backdropFile: nil, stillFile: nil,
            overview: nil, episodeTitle: episodeTitle, rating: nil, genres: nil, metaFetched: true,
            position: 0, duration: 0, lastWatched: nil, watched: false)
    }

    var isRemote: Bool { sourceID == "remote" }
}
