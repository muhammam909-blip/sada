import SwiftUI

@main
struct SadaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    var tab: AppTab = .online
    var playingVideo: VideoItem?
    var deleteVideoCandidate: VideoItem?
    var miniPlayerHidden = false
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

enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case online, folders, videos, library, search
    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .online: "Home"
        case .folders: "Folders"
        case .videos: "Videos"
        case .library: "Library"
        case .search: "Search"
        }
    }

    var icon: String {
        switch self {
        case .online: "house.fill"
        case .folders: "folder.fill"
        case .videos: "play.rectangle.fill"
        case .library: "square.stack.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// Tab order / names / visibility (Settings › Tabs).
enum TabSettings {
    static let orderKey = "tabs.order"
    static let onlineKey = "online.enabled"
    static let videosTabKey = "tabs.videosSeparate"
    static let defaultOrder = "online,folders,library,videos"

    static func order(_ raw: String) -> [AppTab] {
        var tabs = raw.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }.filter { $0 != .search }
        for t in [AppTab.online, .folders, .library, .videos] where !tabs.contains(t) { tabs.append(t) }
        return tabs
    }

    static let hiddenKey = "tabs.hidden"

    static func visible(order raw: String, online: Bool, videosSeparate: Bool, hidden: String = "") -> [AppTab] {
        let hiddenSet = Set(hidden.split(separator: ",").map(String.init))
        let list = order(raw).filter { tab in
            if hiddenSet.contains(tab.rawValue) { return false }
            switch tab {
            case .online: return online
            case .videos: return videosSeparate
            default: return true
            }
        }
        return list.isEmpty ? [.folders] : list
    }

    static func name(_ tab: AppTab) -> String {
        let custom = UserDefaults.standard.string(forKey: "tabs.name.\(tab.rawValue)")?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? tab.defaultName : custom
    }
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
