import AppIntents

struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle All Songs"
    static let description = IntentDescription("Shuffles your whole library in Sada.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerEngine.shared.configure()
        PlayerEngine.shared.shuffleAll(LibraryStore.shared.tracks)
        return .result()
    }
}

struct SadaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShuffleAllIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Play music in \(.applicationName)",
            ],
            shortTitle: "Shuffle All",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Play / Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next song in \(.applicationName)"],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
    }
}
