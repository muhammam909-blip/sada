import Foundation
import Security

struct SubtitleCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    /// Decodes subtitle bytes, handling the common Arabic Windows-1256 encoding.
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let arabic = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        if let s = String(data: data, encoding: arabic) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]), let end = time(parts[1]) else { continue }
            let body = lines[(timeIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func time(_ s: String) -> Double? {
        let clean = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = clean.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        let nums = parts.compactMap(Double.init)
        guard nums.count == parts.count else { return nil }
        return nums.count == 3 ? nums[0] * 3600 + nums[1] * 60 + nums[2] : nums[0] * 60 + nums[1]
    }

    /// Cue showing at `time` (binary search).
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if time < c.start { hi = mid - 1 } else if time > c.end { lo = mid + 1 } else { return c }
        }
        return nil
    }
}

// MARK: - OpenSubtitles.com (free API key from opensubtitles.com/consumers)

enum OpenSubtitles {
    struct Result: Identifiable, Hashable {
        let id: Int // file id
        let release: String
        let language: String
        let downloads: Int
        let hearingImpaired: Bool
    }

    enum Failure: LocalizedError {
        case noKey, http(Int), noLink
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your free OpenSubtitles API key in Settings › Videos."
            case .http(let code): return code == 406 || code == 429
                ? "Daily download limit reached. Sign in to OpenSubtitles in Settings for more."
                : "OpenSubtitles error (\(code))."
            case .noLink: return "Couldn't download that subtitle."
            }
        }
    }

    static var apiKey: String { UserDefaults.standard.string(forKey: "os.apiKey")?.trimmingCharacters(in: .whitespaces) ?? "" }

    private static func request(_ path: String, query: [String: String?] = [:], method: String = "GET", body: [String: Any]? = nil,
                                token: String? = nil) async throws -> Data {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        guard let url = HTTP.url("https://api.opensubtitles.com/api/v1/\(path)", query) else { throw Failure.noLink }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("MHM v0.5", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    static func search(query: String, season: Int?, episode: Int?, languages: String) async throws -> [Result] {
        struct Response: Decodable {
            let data: [Item]
            struct Item: Decodable { let attributes: Attr }
            struct Attr: Decodable {
                let language: String?
                let release: String?
                let download_count: Int?
                let hearing_impaired: Bool?
                let files: [F]
            }
            struct F: Decodable { let file_id: Int }
        }
        let data = try await request("subtitles", query: [
            "query": query, "languages": languages,
            "season_number": season.map(String.init), "episode_number": episode.map(String.init),
        ])
        let res = try JSONDecoder().decode(Response.self, from: data)
        return res.data.compactMap { item in
            guard let file = item.attributes.files.first else { return nil }
            return Result(id: file.file_id, release: item.attributes.release ?? "Subtitle",
                          language: item.attributes.language ?? "?", downloads: item.attributes.download_count ?? 0,
                          hearingImpaired: item.attributes.hearing_impaired ?? false)
        }
        .sorted { $0.downloads > $1.downloads }
    }

    /// Logs in with the saved account (optional; raises the daily download limit).
    private static func token() async -> String? {
        guard let user = Keychain.get("os.username"), let pass = Keychain.get("os.password"), !user.isEmpty else { return nil }
        struct Login: Decodable { let token: String }
        guard let data = try? await request("login", method: "POST", body: ["username": user, "password": pass]),
              let login = try? JSONDecoder().decode(Login.self, from: data) else { return nil }
        return login.token
    }

    static func download(_ result: Result) async throws -> String {
        struct Link: Decodable { let link: String? }
        let auth = await token()
        let data = try await request("download", method: "POST", body: ["file_id": result.id], token: auth)
        guard let link = try JSONDecoder().decode(Link.self, from: data).link, let url = URL(string: link) else { throw Failure.noLink }
        let (file, _) = try await URLSession.shared.data(from: url)
        return SubtitleParser.decode(file)
    }
}

// MARK: - Minimal Keychain helper (for the optional OpenSubtitles password)

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
