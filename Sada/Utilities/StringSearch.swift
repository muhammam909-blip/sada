import Foundation

extension String {
    var containsArabic: Bool {
        unicodeScalars.contains { s in
            (0x0600...0x06FF).contains(s.value) || (0x0750...0x077F).contains(s.value)
                || (0xFB50...0xFDFF).contains(s.value) || (0xFE70...0xFEFF).contains(s.value)
        }
    }

    /// Normalised key for searching / matching: case, diacritics, tashkeel and
    /// common Arabic letter variants (أ إ آ → ا, ة → ه, ى → ي) are folded.
    var searchKey: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for s in folded.unicodeScalars {
            switch s.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue // tashkeel, superscript alef, tatweel
            case 0x0623, 0x0625, 0x0622, 0x0671: scalars.append(Unicode.Scalar(0x0627)!) // alef variants
            case 0x0629: scalars.append(Unicode.Scalar(0x0647)!) // taa marbuta -> haa
            case 0x0649: scalars.append(Unicode.Scalar(0x064A)!) // alef maqsura -> yaa
            case 0x0624: scalars.append(Unicode.Scalar(0x0648)!)
            case 0x0626: scalars.append(Unicode.Scalar(0x064A)!)
            default: scalars.append(s)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TitleCleaner {
    private static let noise = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*(official|video|lyric|audio|remaster|visuali[sz]er|hd|hq|4k|explicit|clip|كليب|فيديو|حصري|اوديو|أوديو|كلمات)[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive])
    private static let feat = try! NSRegularExpression(
        pattern: #"\s*[\(\[]?\s*(feat\.?|ft\.?|featuring|مع)\s+[^\)\]]*[\)\]]?"#,
        options: [.caseInsensitive])
    private static let dashSuffix = try! NSRegularExpression(
        pattern: #"\s+-\s+.*(remaster|version|edit|live|mix).*$"#,
        options: [.caseInsensitive])

    /// Strips things like "(Official Video)", "feat. X" and "- Remastered 2011" for searching.
    static func clean(_ title: String) -> String {
        var s = title
        for re in [noise, dashSuffix] {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanForMatching(_ title: String) -> String {
        var s = clean(title)
        s = feat.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        let key = s.searchKey
        let allowed = key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(allowed))
            .split(separator: " ").joined(separator: " ")
    }
}

enum Matcher {
    /// 0 = no match; higher is better.
    static func score(candidateTitle: String?, candidateArtist: String?, title: String, artist: String?) -> Int {
        guard let candidateTitle else { return 0 }
        let a = TitleCleaner.cleanForMatching(candidateTitle)
        let b = TitleCleaner.cleanForMatching(title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard a == b || a.contains(b) || b.contains(a) else { return 0 }
        var score = a == b ? 3 : 2
        if let artist, !artist.isEmpty, let candidateArtist {
            let x = TitleCleaner.cleanForMatching(candidateArtist)
            let y = TitleCleaner.cleanForMatching(artist)
            if !x.isEmpty, !y.isEmpty, x == y || x.contains(y) || y.contains(x) {
                score += 3
            } else {
                score -= 1
            }
        }
        return score
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
