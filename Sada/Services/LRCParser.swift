import Foundation

struct LyricWord: Hashable {
    let time: Double
    let text: String
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double?
    let text: String
    /// When the next line starts (for the karaoke fill).
    var end: Double? = nil
    /// Word timings from "enhanced" LRC files (<mm:ss.xx> tags), when available.
    var words: [LyricWord] = []
}

struct LyricsDocument: Equatable {
    let lines: [LyricLine]
    let isSynced: Bool
    let isRTL: Bool
}

enum LRCParser {
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)
    private static let metaTag = try! NSRegularExpression(pattern: #"^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$"#)

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> Double {
        let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let secs = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
        return minutes * 60 + secs
    }

    /// Splits "<00:01.20>Hello <00:01.80>world" into timed words and plain text.
    private static func words(in text: String, offset: Double) -> (String, [LyricWord]) {
        let ns = text as NSString
        let matches = wordTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }
        var out: [LyricWord] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let word = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if !word.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(LyricWord(time: max(0, seconds(ns, m) - offset), text: word))
            }
        }
        let plain = wordTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (plain.trimmingCharacters(in: .whitespaces), out)
    }

    static func parse(_ raw: String) -> LyricsDocument {
        var timed: [(Double, String, [LyricWord])] = []
        var plain: [String] = []
        var offset = 0.0

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = timeTag.matches(in: line, range: full)

            if matches.isEmpty {
                if line.lowercased().hasPrefix("[offset:") {
                    let value = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                    offset = (Double(value) ?? 0) / 1000
                } else if metaTag.firstMatch(in: line, range: full) == nil {
                    plain.append(line)
                }
                continue
            }

            let last = matches[matches.count - 1]
            let rest = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            let (text, wordList) = words(in: rest, offset: offset)
            for m in matches {
                timed.append((max(0, seconds(ns, m) - offset), text, wordList))
            }
        }

        let isRTL = raw.containsArabic
        if !timed.isEmpty {
            let sorted = timed.sorted { $0.0 < $1.0 }
            var compact: [(Double, String, [LyricWord])] = []
            for entry in sorted {
                if entry.1.isEmpty, let prev = compact.last, prev.1.isEmpty { continue }
                compact.append(entry)
            }
            var lines: [LyricLine] = []
            for (i, e) in compact.enumerated() {
                let end = i + 1 < compact.count ? compact[i + 1].0 : nil
                lines.append(LyricLine(id: i, time: e.0, text: e.1, end: end, words: e.2))
            }
            return LyricsDocument(lines: lines, isSynced: true, isRTL: isRTL)
        }

        var cleaned: [String] = []
        for line in plain {
            if line.isEmpty, cleaned.last?.isEmpty ?? true { continue }
            cleaned.append(line)
        }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        let lines = cleaned.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
        return LyricsDocument(lines: lines, isSynced: false, isRTL: isRTL)
    }
}
