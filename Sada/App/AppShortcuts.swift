import AppIntents

struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle All Songs"
    static let description = IntentDescription("Shuffles your whole library in MHM.")

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
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play \(\.$artist) in \(.applicationName)",
                "Shuffle \(\.$artist) in \(.applicationName)",
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.microphone"
        )
        AppShortcut(
            intent: ContinueShowIntent(),
            phrases: [
                "Continue \(\.$show) in \(.applicationName)",
                "Watch \(\.$show) in \(.applicationName)",
            ],
            shortTitle: "Continue Show",
            systemImageName: "play.tv"
        )
        AppShortcut(
            intent: ResumeLastVideoIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Resume my movie in \(.applicationName)",
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.rectangle.fill"
        )
    }
}
