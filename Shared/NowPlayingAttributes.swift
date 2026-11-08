import ActivityKit
import Foundation

/// Live Activity used for the optional "live lyrics" Dynamic Island.
/// (The regular Now Playing Dynamic Island comes from the system via MPNowPlayingInfoCenter.)
struct NowPlayingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var artworkFile: String?
        /// Tiny JPEG (≈1–2 KB) embedded so the island never depends on shared storage.
        var artworkThumb: Data?
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var updatedAt: Date
        var lyricLine: String?
        var nextLyricLine: String?

        var startDate: Date { updatedAt.addingTimeInterval(-elapsed) }
        var endDate: Date { startDate.addingTimeInterval(max(duration, 1)) }
        var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
    }
}
