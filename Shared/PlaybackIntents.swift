import AppIntents
import Foundation

// These intents are compiled into both the app and the widget extension.
// AudioPlaybackIntent makes the system run them inside the app process,
// so the widget/Live Activity buttons control the real player.

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the music in Sada.")

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { PlayerEngine.shared.togglePlayPause() }
        #endif
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { PlayerEngine.shared.next() }
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { PlayerEngine.shared.previous() }
        #endif
        return .result()
    }
}
