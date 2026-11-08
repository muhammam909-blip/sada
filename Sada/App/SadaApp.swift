import SwiftUI

@main
struct SadaApp: App {
    @State private var library = LibraryStore.shared
    @State private var player = PlayerEngine.shared
    @State private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PlayerEngine.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(router)
                .task { await library.bootstrap() }
                .onOpenURL { url in
                    if url.isFileURL {
                        Task { await library.importFiles([url]) }
                    } else if url.scheme == "sada" {
                        router.showNowPlaying = player.current != nil
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: player.persistState()
            case .active: Task { await library.rescanIfNeeded() }
            default: break
            }
        }
    }
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var showNowPlaying = false
    var trackSheet: TrackSheet?
    var deleteCandidate: Track?
    var tab: AppTab = .home
    var onlineQuery: String?
}

enum TrackSheet: Identifiable {
    case edit(Track)
    case artwork(Track)
    case lyrics(Track)
    case addToPlaylist(Track)
    case move([String])
    case moveItems(tracks: [String], folders: [String], source: String?)
    case addSongs(playlistID: String?) // nil = Favorites

    var id: String {
        switch self {
        case .edit(let t): "edit-\(t.id)"
        case .artwork(let t): "art-\(t.id)"
        case .lyrics(let t): "lyr-\(t.id)"
        case .addToPlaylist(let t): "pl-\(t.id)"
        case .move(let ids): "move-\(ids.joined(separator: ","))"
        case .moveItems(let t, let f, _): "moveitems-\(t.count)-\(f.joined(separator: ","))"
        case .addSongs(let p): "add-\(p ?? "fav")"
        }
    }
}

enum AppTab: Hashable {
    case home, library, online, search
}

enum Appearance: String, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", system = "System"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum AppSettings {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var autoArtwork: Bool { bool("autoArtwork", default: true) }
    static var autoLyrics: Bool { bool("autoLyrics", default: true) }
    static var lyricsInDynamicIsland: Bool { bool("lyricsInDynamicIsland", default: false) }
}
