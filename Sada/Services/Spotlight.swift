import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Makes songs and videos searchable from the iPhone's Spotlight search.
enum SpotlightIndex {
    static let musicDomain = "com.hammam.sada.music"
    static let videoDomain = "com.hammam.sada.videos"

    @MainActor
    static func indexMusic() {
        let library = LibraryStore.shared
        let items: [CSSearchableItem] = library.tracks.map { t in
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = t.title
            attrs.displayName = t.title
            attrs.artist = t.displayArtist
            attrs.album = t.displayAlbum
            attrs.contentDescription = "\(t.displayArtist) · \(t.displayAlbum)"
            attrs.duration = NSNumber(value: t.duration)
            if t.hasArtwork { attrs.thumbnailURL = library.artworkFileURL(t.id) }
            attrs.keywords = [t.displayArtist, t.displayAlbum, "MHM", "music"]
            return CSSearchableItem(uniqueIdentifier: "track:\(t.id)", domainIdentifier: musicDomain, attributeSet: attrs)
        }
        replace(domain: musicDomain, with: items)
    }

    @MainActor
    static func indexVideos() {
        let store = VideoStore.shared
        let items: [CSSearchableItem] = store.videos.filter { !$0.isRemote }.map { v in
            let attrs = CSSearchableItemAttributeSet(contentType: .movie)
            let name = v.kind == .episode ? "\(v.showName ?? v.title) · \(v.episodeCode ?? "")" : v.title
            attrs.title = name
            attrs.displayName = name
            attrs.contentDescription = v.kind == .episode ? v.displayTitle : (v.overview ?? v.genres)
            if let file = v.stillFile ?? v.posterFile { attrs.thumbnailURL = store.artURL(file) }
            attrs.keywords = [v.showName ?? v.title, v.kind == .episode ? "episode" : "movie", "MHM"]
            return CSSearchableItem(uniqueIdentifier: "video:\(v.id)", domainIdentifier: videoDomain, attributeSet: attrs)
        }
        replace(domain: videoDomain, with: items)
    }

    private static func replace(domain: String, with items: [CSSearchableItem]) {
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Opens what was tapped in Spotlight.
    @MainActor
    static func open(_ identifier: String) {
        if identifier.hasPrefix("track:") {
            let id = String(identifier.dropFirst(6))
            guard let track = LibraryStore.shared.track(id: id) else { return }
            let album = LibraryStore.shared.album(id: track.albumID)?.tracks ?? [track]
            PlayerEngine.shared.play(album, startAt: album.firstIndex { $0.id == id } ?? 0, shuffle: false)
            AppRouter.shared.showNowPlaying = true
        } else if identifier.hasPrefix("video:") {
            let id = String(identifier.dropFirst(6))
            if let video = VideoStore.shared.video(id: id) { AppRouter.shared.playingVideo = video }
        }
    }
}
