import AVFoundation
import Foundation

struct AudioMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double = 0
    var artwork: Data?
    var lyrics: String?
}

enum MetadataReader {
    static func read(url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        var m = AudioMetadata()

        if let d = try? await asset.load(.duration), d.isNumeric { m.duration = d.seconds }

        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) { items += common }
        if let all = try? await asset.load(.metadata) { items += all }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let extra = try? await asset.loadMetadata(for: format) { items += extra }
            }
        }

        for item in items {
            await apply(item, to: &m)
        }

        // Fall back to the file name: "01 - Artist - Title.mp3" / "Artist - Title.mp3"
        if m.title == nil || m.title?.isEmpty == true {
            let parsed = parseFileName(url.deletingPathExtension().lastPathComponent)
            m.title = parsed.title
            if m.artist == nil || m.artist?.isEmpty == true { m.artist = parsed.artist }
            if m.trackNumber == nil { m.trackNumber = parsed.track }
        }
        return m
    }

    private static func apply(_ item: AVMetadataItem, to m: inout AudioMetadata) async {
        let identifier = item.identifier
        let key = ((item.key as? String) ?? "").uppercased()

        func str() async -> String? {
            let value = try? await item.load(.stringValue)
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        if let identifier {
        switch identifier {
        case .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName:
            if m.title == nil { m.title = await str() }
            return
        case .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist:
            if m.artist == nil { m.artist = await str() }
            return
        case .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum:
            if m.album == nil { m.album = await str() }
            return
        case .iTunesMetadataAlbumArtist, .id3MetadataBand:
            if m.albumArtist == nil { m.albumArtist = await str() }
            return
        case .commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt:
            if m.artwork == nil { m.artwork = try? await item.load(.dataValue) }
            return
        case .id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics:
            if m.lyrics == nil { m.lyrics = await str() }
            return
        case .iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre:
            if m.genre == nil { m.genre = await str() }
            return
        case .id3MetadataTrackNumber:
            if m.trackNumber == nil, let s = await str() { m.trackNumber = leadingInt(s) }
            return
        case .id3MetadataPartOfASet:
            if m.discNumber == nil, let s = await str() { m.discNumber = leadingInt(s) }
            return
        case .iTunesMetadataTrackNumber:
            if m.trackNumber == nil, let d = try? await item.load(.dataValue), d.count >= 4 {
                m.trackNumber = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
            }
            return
        case .iTunesMetadataDiscNumber:
            if m.discNumber == nil, let d = try? await item.load(.dataValue), d.count >= 4 {
                m.discNumber = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
            }
            return
        case .commonIdentifierCreationDate, .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate:
            if m.year == nil, let s = await str() { m.year = leadingInt(String(s.prefix(4))) }
            return
        default:
            break
        }
        }

        // Vorbis comments (FLAC) and other key-based formats.
        switch key {
        case "TITLE": if m.title == nil { m.title = await str() }
        case "ARTIST": if m.artist == nil { m.artist = await str() }
        case "ALBUM": if m.album == nil { m.album = await str() }
        case "ALBUMARTIST", "ALBUM ARTIST": if m.albumArtist == nil { m.albumArtist = await str() }
        case "GENRE": if m.genre == nil { m.genre = await str() }
        case "TRACKNUMBER": if m.trackNumber == nil, let s = await str() { m.trackNumber = leadingInt(s) }
        case "DISCNUMBER": if m.discNumber == nil, let s = await str() { m.discNumber = leadingInt(s) }
        case "DATE", "YEAR": if m.year == nil, let s = await str() { m.year = leadingInt(String(s.prefix(4))) }
        case "LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS": if m.lyrics == nil { m.lyrics = await str() }
        default: break
        }
    }

    private static func leadingInt(_ s: String) -> Int? {
        let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return Int(digits)
    }

    static func parseFileName(_ name: String) -> (title: String, artist: String?, track: Int?) {
        var base = name.replacingOccurrences(of: "_", with: " ")
        var track: Int?
        // Leading track number: "01 - ", "01. ", "1 "
        if let match = base.range(of: #"^\d{1,3}\s*[-.\s]\s*"#, options: .regularExpression) {
            track = leadingInt(String(base[match]))
            base.removeSubrange(match)
        }
        let parts = base.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, !parts[0].isEmpty {
            return (parts.dropFirst().joined(separator: " - "), parts[0], track)
        }
        return (base.trimmingCharacters(in: .whitespaces), nil, track)
    }
}
