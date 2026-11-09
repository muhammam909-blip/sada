import Foundation
import SwiftUI
import YouTubeKit

/// Long-form YouTube videos (movies / episodes), preferring verified (official) channels.
enum YouTubeVideos {
    struct Result: Identifiable, Hashable {
        let id: String
        let title: String
        let channel: String
        let verified: Bool
        let seconds: Int
        let thumbnail: URL?
        let views: String?
    }

    enum Length { case long, any }

    static func search(_ query: String, length: Length = .long, region: String = "EG") async -> [Result] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250312.04.00", "hl": "ar", "gl": region]],
            "query": query,
            "params": length == .long ? "EgQQARgC" : "EgIQAQ==", // videos only (+ longer than 20 minutes)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = data
        guard case let (resp, response)? = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else { return [] }
        var renderers: [[String: Any]] = []
        YTMusicSearch.collect(json, key: "videoRenderer", into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap(parse).filter { seen.insert($0.id).inserted }
    }

    private static func text(_ node: Any?) -> String? {
        guard let d = node as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }

    private static func parse(_ r: [String: Any]) -> Result? {
        guard let id = r["videoId"] as? String, let title = text(r["title"]) else { return nil }
        let length = text(r["lengthText"]) ?? ""
        let seconds = length.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        let badges = (r["ownerBadges"] as? [[String: Any]]) ?? []
        let verified = badges.contains {
            let style = ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String ?? ""
            return style.contains("VERIFIED")
        }
        let thumbs = ((r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        return Result(id: id, title: title, channel: text(r["ownerText"]) ?? "", verified: verified, seconds: seconds,
                      thumbnail: (thumbs.last?["url"] as? String).flatMap(URL.init(string:)), views: text(r["viewCountText"]))
    }

    /// 1080p/720p H.264 video plus AAC audio (VLC joins them), or a combined stream as fallback.
    static func playableStreams(_ id: String) async -> (video: URL, audio: URL?)? {
        guard let streams = try? await YouTube(videoID: id).streams else { return nil }
        let preferredVideo = [137, 136, 135]
        if let audio = streams.first(where: { $0.itag == 140 }) ?? streams.filterAudioOnly().highestAudioBitrateStream() {
            for itag in preferredVideo {
                if let video = streams.first(where: { $0.itag == itag }) { return (video.url, audio.url) }
            }
        }
        if let muxed = streams.filterVideoAndAudio().highestResolutionStream() { return (muxed.url, nil) }
        return nil
    }

    static func item(for r: Result, title: String? = nil, kind: VideoKind = .movie, show: String? = nil,
                     season: Int? = nil, episode: Int? = nil) async -> VideoItem? {
        guard let s = await playableStreams(r.id) else { return nil }
        var item = VideoItem.remote(url: s.video, title: title ?? r.title, kind: kind, show: show, season: season, episode: episode)
        item.audioURL = s.audio?.absoluteString
        return item
    }
}

/// Built-in, legal sources that are checked when you press Play in Discover.
enum BuiltInSources {
    static let youtubeName = "YouTube · official uploads"
    static let archiveName = "Internet Archive · public domain"

    /// Arabic title of a film/series from Wikidata (via its IMDb id), for Arabic YouTube searches.
    static func arabicName(imdb: String) async -> String? {
        guard imdb.hasPrefix("tt"),
              let url = HTTP.url("https://www.wikidata.org/w/api.php", [
                  "action": "query", "list": "search", "srsearch": "haswbstatement:P345=\(imdb)", "srlimit": "1", "format": "json",
              ]),
              case let (data, 200)? = await HTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = (((json["query"] as? [String: Any])?["search"] as? [[String: Any]])?.first)?["title"] as? String,
              let labelURL = HTTP.url("https://www.wikidata.org/w/api.php", [
                  "action": "wbgetentities", "ids": q, "props": "labels", "languages": "ar", "format": "json",
              ]),
              case let (labelData, 200)? = await HTTP.get(labelURL),
              let labels = try? JSONSerialization.jsonObject(with: labelData) as? [String: Any],
              let entity = (labels["entities"] as? [String: Any])?[q] as? [String: Any],
              let ar = ((entity["labels"] as? [String: Any])?["ar"] as? [String: Any])?["value"] as? String
        else { return nil }
        return ar
    }

    static func streams(type: String, meta: MetaDetail?, videoID: String, episode: MetaDetail.Video?) async -> [StreamOption] {
        guard let meta else { return [] }
        async let yt = youtube(meta: meta, episode: episode)
        async let archive = type == "movie" ? internetArchive(meta: meta) : []
        return await yt + archive
    }

    private static func matches(_ title: String, any names: [String]) -> Bool {
        let t = title.searchKey
        return names.contains { name in
            let words = name.searchKey.split(separator: " ").filter { $0.count > 2 }
            guard !words.isEmpty else { return t.contains(name.searchKey) }
            let hits = words.filter { t.contains($0) }.count
            return Double(hits) / Double(words.count) >= 0.6
        }
    }

    private static func youtube(meta: MetaDetail, episode: MetaDetail.Video?) async -> [StreamOption] {
        let arabic = await arabicName(imdb: meta.id)
        let names = [meta.name] + (arabic.map { [$0] } ?? [])
        let year = meta.releaseInfo.map { String($0.prefix(4)) } ?? ""
        var queries: [String] = []
        if let ep = episode, let n = ep.episode {
            if let arabic { queries.append("\(arabic) الحلقة \(n)") }
            queries.append("\(meta.name) season \(ep.season ?? 1) episode \(n)")
        } else {
            if let arabic { queries.append("\(arabic) فيلم كامل") }
            queries.append("\(meta.name) \(year) full movie")
        }
        let minSeconds = episode == nil ? 55 * 60 : 15 * 60
        var found: [YouTubeVideos.Result] = []
        for q in queries { found += await YouTubeVideos.search(q, length: .long) }
        var seen = Set<String>()
        let good = found.filter { r in
            seen.insert(r.id).inserted && r.seconds >= minSeconds && matches(r.title, any: names)
                && (episode?.episode.map { n in r.title.contains("\(n)") } ?? true)
        }
        .sorted { ($0.verified ? 0 : 1, -$0.seconds) < ($1.verified ? 0 : 1, -$1.seconds) }
        .filter(\.verified) // official channels only
        return good.prefix(6).map { r in
            StreamOption(addon: youtubeName, title: r.title,
                         subtitle: "\(r.channel) ✓ · \(formatTime(Double(r.seconds)))\(r.views.map { " · \($0)" } ?? "")",
                         url: nil, ytId: r.id, isTorrent: false, headers: [:])
        }
    }

    private static func internetArchive(meta: MetaDetail) async -> [StreamOption] {
        struct Search: Decodable {
            let response: R
            struct R: Decodable { let docs: [Doc] }
            struct Doc: Decodable { let identifier: String; let title: String?; let year: String? }
        }
        struct Meta: Decodable {
            let files: [F]?
            struct F: Decodable { let name: String; let format: String?; let size: String? }
        }
        let year = meta.releaseInfo.flatMap { Int($0.prefix(4)) }
        let safeName = meta.name.replacingOccurrences(of: "\"", with: "")
        guard let url = HTTP.url("https://archive.org/advancedsearch.php", [
            "q": "title:(\"\(safeName)\") AND mediatype:(movies)", "fl[]": "identifier", "rows": "5", "output": "json",
        ]) else { return [] }
        // advancedsearch needs several fl[] values; append the rest manually.
        guard let full = URL(string: url.absoluteString + "&fl%5B%5D=title&fl%5B%5D=year"),
              case let (data, 200)? = await HTTP.get(full),
              let res = try? JSONDecoder().decode(Search.self, from: data) else { return [] }
        var out: [StreamOption] = []
        for doc in res.response.docs.prefix(3) {
            if let y = year, let docYear = doc.year.flatMap({ Int($0.prefix(4)) }), abs(docYear - y) > 1 { continue }
            guard matches(doc.title ?? "", any: [meta.name]),
                  let mURL = URL(string: "https://archive.org/metadata/\(doc.identifier)"),
                  case let (mData, 200)? = await HTTP.get(mURL),
                  let m = try? JSONDecoder().decode(Meta.self, from: mData),
                  let file = m.files?.filter({ $0.name.lowercased().hasSuffix(".mp4") })
                      .max(by: { (Int($0.size ?? "") ?? 0) < (Int($1.size ?? "") ?? 0) }),
                  let fileURL = URL(string: "https://archive.org/download/\(doc.identifier)/\(file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name)")
            else { continue }
            out.append(StreamOption(addon: archiveName, title: doc.title ?? meta.name, subtitle: file.name,
                                    url: fileURL, ytId: nil, isTorrent: false, headers: [:]))
        }
        return out
    }
}

// MARK: - Arabic & free rows for Discover

struct YouTubeRow: Identifiable {
    let id: String
    let title: String
    let items: [YouTubeVideos.Result]

    static let queries: [(id: String, title: String, query: String)] = [
        ("eg-movies", "Egyptian Movies", "فيلم مصري كامل"),
        ("eg-comedy", "Egyptian Comedy", "فيلم كوميدي مصري كامل"),
        ("eg-classics", "Egyptian Classics", "فيلم أبيض وأسود كامل"),
        ("ar-series", "Arabic Series · Episode 1", "مسلسل الحلقة الأولى"),
        ("free-movies", "Free Movies", "full movie free official"),
        ("docs", "Documentaries", "full documentary"),
    ]
}

struct YouTubeCard: View {
    let item: YouTubeVideos.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AsyncImage(url: item.thumbnail, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary).shimmering() }
            }
            .frame(width: 220, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(formatTime(Double(item.seconds)))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
            HStack(spacing: 4) {
                Text(item.channel).lineLimit(1)
                if item.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 220, alignment: .leading)
    }
}
