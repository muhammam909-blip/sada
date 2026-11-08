import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "sada://nowplaying"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetArtwork(file: s.artworkFile, cornerRadius: 10)
                        .frame(width: 56, height: 56)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 14) {
                        Button(intent: TogglePlaybackIntent()) {
                            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        }
                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill").font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let line = s.lyricLine, !line.isEmpty {
                            Text(line)
                                .font(.system(size: 17, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                                .contentTransition(.opacity)
                        }
                        LiveProgress(state: s).tint(.white)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                WidgetArtwork(file: s.artworkFile, cornerRadius: 6)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                if let line = s.lyricLine, !line.isEmpty {
                    Text(line)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 64)
                } else {
                    Image(systemName: s.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(.pink)
                }
            } minimal: {
                WidgetArtwork(file: s.artworkFile, cornerRadius: 11)
                    .frame(width: 22, height: 22)
            }
            .keylineTint(.pink)
            .widgetURL(URL(string: "sada://nowplaying"))
        }
    }
}

struct LiveProgress: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        if state.isPlaying, state.endDate > Date() {
            ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        } else {
            ProgressView(value: state.progress)
        }
    }
}

struct LockScreenLiveView: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                WidgetArtwork(file: state.artworkFile, cornerRadius: 10)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text(state.artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .buttonStyle(.plain)
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(.plain)
            }
            if let line = state.lyricLine, !line.isEmpty {
                Text(line)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: line.containsArabicScript ? .trailing : .leading)
                    .multilineTextAlignment(line.containsArabicScript ? .trailing : .leading)
            }
            LiveProgress(state: state).tint(.white)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private extension String {
    var containsArabicScript: Bool {
        unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }
}
