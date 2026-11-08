import ActivityKit
import Foundation

/// Optional "live lyrics" Live Activity. The standard Now Playing Dynamic Island
/// is provided by iOS itself through MPNowPlayingInfoCenter.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<NowPlayingAttributes>?
    private var lastState: NowPlayingAttributes.ContentState?

    private init() {}

    func sync(engine: PlayerEngine, force: Bool = false) {
        guard AppSettings.lyricsInDynamicIsland,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let track = engine.current
        else {
            end()
            return
        }

        let state = NowPlayingAttributes.ContentState(
            title: track.title,
            artist: track.displayArtist,
            artworkFile: SharedArtwork.export(track, library: LibraryStore.shared),
            isPlaying: engine.isPlaying,
            elapsed: engine.currentTime,
            duration: engine.duration,
            updatedAt: Date(),
            lyricLine: engine.currentLyricText,
            nextLyricLine: engine.nextLyricText
        )

        if !force, let last = lastState,
           last.title == state.title, last.artist == state.artist,
           last.isPlaying == state.isPlaying, last.lyricLine == state.lyricLine {
            return
        }
        lastState = state

        let content = ActivityContent(state: state, staleDate: nil)
        if activity == nil { activity = Activity<NowPlayingAttributes>.activities.first }

        if let activity, activity.activityState == .active || activity.activityState == .stale {
            Task { await activity.update(content) }
        } else {
            // Requests only succeed while the app is in the foreground; that's fine.
            activity = try? Activity.request(attributes: NowPlayingAttributes(), content: content, pushType: nil)
        }
    }

    func end() {
        let all = Activity<NowPlayingAttributes>.activities
        activity = nil
        lastState = nil
        guard !all.isEmpty else { return }
        Task {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
