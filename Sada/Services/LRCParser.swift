import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double?
    let text: String
}

struct LyricsDocument: Equatable {
    let lines: [LyricLine]
    let isSynced: Bool
    let isRTL: Bool
}

enum LRCParser {
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let metaTag = try! NSRegularExpression(pattern: #"^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$"#)

    static func parse(_ raw: String) -> LyricsDocument {
        var timed: [(Double, String)] = []
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
            let textStart = last.range.location + last.range.length
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((max(0, minutes * 60 + seconds - offset), text))
            }
        }

        let isRTL = raw.containsArabic
        if !timed.isEmpty {
            let sorted = timed.sorted { $0.0 < $1.0 }
            var lines: [LyricLine] = []
            for (i, entry) in sorted.enumerated() {
                // Collapse consecutive empty (instrumental) lines.
                if entry.1.isEmpty, let prev = lines.last, prev.text.isEmpty { continue }
                lines.append(LyricLine(id: i, time: entry.0, text: entry.1))
            }
            // Re-number ids so they are contiguous indices.
            lines = lines.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
            return LyricsDocument(lines: lines, isSynced: true, isRTL: isRTL)
        }

        // Plain lyrics: trim leading/trailing blanks and collapse runs of empty lines.
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
