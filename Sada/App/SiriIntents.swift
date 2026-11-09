import AppIntents
import Foundation

// MARK: - Artists ("Play Amr Diab in MHM")

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ArtistQuery: EntityStringQuery {
    @MainActor
    private func all() -> [ArtistEntity] {
        LibraryStore.shared.artists.map { ArtistEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ArtistEntity] {
        let key = string.searchKey
        return all().filter { $0.name.searchKey.contains(key) || key.contains($0.name.searchKey) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ArtistEntity] {
        Array(LibraryStore.shared.artists.sorted { $0.tracks.count > $1.tracks.count }.prefix(30)
            .map { ArtistEntity(id: $0.id, name: $0.name) })
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Shuffles an artist from your MHM library.")

    @Parameter(title: "Artist") var artist: ArtistEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let found = LibraryStore.shared.artist(id: artist.id) else { return .result() }
        PlayerEngine.shared.configure()
        PlayerEngine.shared.shuffleAll(found.tracks)
        return .result()
    }
}

// MARK: - Shows ("Continue The Sopranos in MHM")

struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let defaultQuery = ShowQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ShowQuery: EntityStringQuery {
    @MainActor
    private func all() -> [ShowEntity] {
        let store = VideoStore.shared
        return store.shows.map { ShowEntity(id: $0.id, name: $0.name) }
            + store.movies.map { ShowEntity(id: "movie:\($0.id)", name: $0.title) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShowEntity] {
        let key = string.searchKey
        return all().filter { $0.name.searchKey.contains(key) || key.contains($0.name.searchKey) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ShowEntity] { Array(all().prefix(30)) }
}

struct ContinueShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes a show or movie in MHM.")
    static let openAppWhenRun = true

    @Parameter(title: "Show or Movie") var show: ShowEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = VideoStore.shared
        let item: VideoItem?
        if show.id.hasPrefix("movie:") {
            item = store.video(id: String(show.id.dropFirst(6)))
        } else {
            item = store.show(id: show.id)?.nextUp
        }
        if let item { AppRouter.shared.playingVideo = item }
        return .result()
    }
}

struct ResumeLastVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Last Video"
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if let item = VideoStore.shared.continueWatching.first { AppRouter.shared.playingVideo = item }
        return .result()
    }
}
