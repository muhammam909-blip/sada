import Foundation

struct Track: Identifiable, Codable, Hashable {
    var id: String
    var relativePath: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double
    var fileSize: Int64
    var modifiedAt: Date
    var dateAdded: Date
    var hasArtwork: Bool
    var hasLyrics: Bool
    var artworkFetched: Bool
    var lyricsFetched: Bool
    var playCount: Int
    var lastPlayed: Date?
    /// nil = the app's own Documents folder, otherwise a LinkedFolder id.
    var sourceID: String?
    var favorite: Bool?

    var isFavorite: Bool { favorite ?? false }

    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

    var displayArtist: String { artist.isEmpty ? Self.unknownArtist : artist }
    var displayAlbum: String { album.isEmpty ? Self.unknownAlbum : album }
    var albumArtistName: String {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return displayArtist
    }
    var albumID: String { "\(albumArtistName.searchKey)|\(displayAlbum.searchKey)" }
    var hasKnownArtist: Bool { !artist.isEmpty && artist != Self.unknownArtist }
    var hasKnownAlbum: Bool { !album.isEmpty && album != Self.unknownAlbum }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
    let year: Int?
    let dateAdded: Date

    var artworkTrack: Track? { tracks.first(where: \.hasArtwork) ?? tracks.first }
    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let tracks: [Track]
    let albums: [Album]

    var artworkTrack: Track? { tracks.first(where: \.hasArtwork) ?? tracks.first }
}

/// A folder from another app (e.g. nPlayer) that is read in place, without copying.
struct LinkedFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bookmark: Data
}

struct Playlist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var trackIDs: [String]
    var createdAt: Date
}

enum Route: Hashable {
    case album(String)
    case artist(String)
    case songs
    case albums
    case artists
    case playlists
    case playlist(String)
    case favorites
}
