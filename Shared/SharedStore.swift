import Foundation

/// Resolves the App Group. SideStore/AltStore rename app groups (they append the team ID)
/// and write the real identifiers into `ALTAppGroups` in Info.plist, so we read that first.
enum AppGroup {
    static let defaultID = "group.com.hammam.sada"

    static let identifier: String = {
        var candidates: [String] = []
        func add(_ bundle: Bundle?) {
            if let groups = bundle?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
                candidates.append(contentsOf: groups)
            }
        }
        add(.main)
        // When running inside the widget extension, also look at the host app bundle.
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if hostURL.pathExtension == "app" { add(Bundle(url: hostURL)) }
        candidates.append(defaultID)
        for id in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
            return id
        }
        return defaultID
    }()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// What the widgets show. Written by the app, read by the widget extension.
struct WidgetSnapshot: Codable {
    struct Item: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var artworkFile: String?
    }

    var current: Item?
    var isPlaying: Bool
    var upNext: [Item]
    var updatedAt: Date

    static let empty = WidgetSnapshot(current: nil, isPlaying: false, upNext: [], updatedAt: .distantPast)
}

enum SharedStore {
    static var artworkDirectory: URL? {
        guard let container = AppGroup.containerURL else { return nil }
        let dir = container.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func artworkURL(_ file: String?) -> URL? {
        guard let file, let dir = artworkDirectory else { return nil }
        return dir.appendingPathComponent(file)
    }

    private static var snapshotURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-snapshot.json")
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
