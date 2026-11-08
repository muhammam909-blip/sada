import Foundation

/// Walks the library in the background and fills in missing artwork and lyrics.
@MainActor
final class MetadataEnricher {
    static let shared = MetadataEnricher()

    private var running = false
    private var rerunRequested = false

    private init() {}

    func start() {
        guard !running else {
            rerunRequested = true
            return
        }
        running = true
        Task {
            repeat {
                rerunRequested = false
                await run()
            } while rerunRequested
            running = false
            LibraryStore.shared.enrichmentStatus = nil
        }
    }

    private func run() async {
        let library = LibraryStore.shared
        let pending = library.tracks.filter {
            (AppSettings.autoArtwork && !$0.hasArtwork && !$0.artworkFetched)
                || (AppSettings.autoLyrics && !$0.hasLyrics && !$0.lyricsFetched)
        }
        guard !pending.isEmpty else { return }

        for (n, snapshot) in pending.enumerated() {
            guard let track = library.track(id: snapshot.id) else { continue }
            library.enrichmentStatus = "Finding artwork & lyrics… \(n + 1)/\(pending.count)"

            if AppSettings.autoArtwork, !track.hasArtwork, !track.artworkFetched {
                await fetchArtwork(for: track)
                try? await Task.sleep(for: .milliseconds(700)) // be polite to the free APIs
            }
            if AppSettings.autoLyrics, let fresh = library.track(id: track.id), !fresh.hasLyrics, !fresh.lyricsFetched {
                _ = await fetchLyrics(for: fresh, force: false)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    @discardableResult
    func fetchArtwork(for track: Track) async -> Bool {
        let library = LibraryStore.shared
        let result = await ArtworkFetcher.fetch(
            title: track.title,
            artist: track.hasKnownArtist ? track.artist : nil,
            album: track.hasKnownAlbum ? track.album : nil
        )
        switch result {
        case .found(let data):
            await library.setArtwork(data, for: track.id, applyToAlbum: true)
            return true
        case .notFound:
            library.markFetched(track.id, artwork: true)
            return false
        case .failed:
            return false
        }
    }

    func fetchLyrics(for track: Track, force: Bool) async -> String? {
        let library = LibraryStore.shared
        if !force, let fresh = library.track(id: track.id), let text = library.lyricsText(for: fresh) {
            return text
        }
        let result = await LyricsFetcher.fetch(
            title: track.title,
            artist: track.hasKnownArtist ? track.artist : nil,
            album: track.hasKnownAlbum ? track.album : nil,
            duration: track.duration
        )
        switch result {
        case .found(let text):
            library.setLyrics(text, for: track.id)
            return text
        case .notFound:
            library.markFetched(track.id, lyrics: true)
            return nil
        case .failed:
            return nil
        }
    }

    /// Manual "search again" from the UI.
    func refetchArtwork(for track: Track) async -> Bool {
        LibraryStore.shared.resetFetchFlags(track.id, artwork: true, lyrics: false)
        return await fetchArtwork(for: track)
    }
}
