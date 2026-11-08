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
}

enum AppSettings {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var autoArtwork: Bool { bool("autoArtwork", default: true) }
    static var autoLyrics: Bool { bool("autoLyrics", default: true) }
    static var lyricsInDynamicIsland: Bool { bool("lyricsInDynamicIsland", default: false) }
}
