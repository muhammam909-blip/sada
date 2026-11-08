import AppIntents
import SwiftUI
import WidgetKit

@main
struct SadaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        current: .init(id: "p", title: "Song Title", artist: "Artist", artworkFile: nil),
        isPlaying: true,
        upNext: [
            .init(id: "a", title: "Next Song", artist: "Artist", artworkFile: nil),
            .init(id: "b", title: "Another One", artist: "Artist", artworkFile: nil),
            .init(id: "c", title: "Third Song", artist: "Artist", artworkFile: nil),
        ],
        updatedAt: .now
    )
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let snap = SharedStore.load()
        completion(NowPlayingEntry(date: .now, snapshot: (context.isPreview && snap.current == nil) ? .preview : snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now, snapshot: SharedStore.load())], policy: .never))
    }
}

// MARK: - Shared bits

struct WidgetArtwork: View {
    let file: String?
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url = SharedStore.artworkURL(file), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.9)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct WidgetBackdrop: View {
    let file: String?

    var body: some View {
        ZStack {
            Color.black
            if let url = SharedStore.artworkURL(file), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 30)
                    .opacity(0.85)
            } else {
                LinearGradient(colors: [Color(red: 0.45, green: 0.1, blue: 0.3), Color(red: 0.15, green: 0.05, blue: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.3)
        }
    }
}

struct WidgetControls: View {
    let isPlaying: Bool
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill").frame(maxWidth: .infinity)
            }
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 1.3))
                    .frame(maxWidth: .infinity)
            }
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill").frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: size))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("See and control what's playing in MHM.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    private var snap: WidgetSnapshot { entry.snapshot }
    private var title: String { snap.current?.title ?? "Not Playing" }
    private var artist: String { snap.current?.artist ?? "Tap play to shuffle your music" }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .systemMedium: medium
        case .systemLarge: large
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetArtwork(file: snap.current?.artworkFile, cornerRadius: 10)
                    .frame(width: 64, height: 64)
                    .shadow(radius: 4)
                Spacer()
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: snap.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.22), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(artist).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(14)
        .containerBackground(for: .widget) { WidgetBackdrop(file: snap.current?.artworkFile) }
        .widgetURL(URL(string: "sada://nowplaying"))
    }

    private var medium: some View {
        HStack(spacing: 14) {
            WidgetArtwork(file: snap.current?.artworkFile, cornerRadius: 12)
                .frame(width: 128, height: 128)
                .shadow(radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(2)
                Text(artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 8)
                WidgetControls(isPlaying: snap.isPlaying, size: 20)
            }
            .foregroundStyle(.white)
        }
        .padding(14)
        .containerBackground(for: .widget) { WidgetBackdrop(file: snap.current?.artworkFile) }
        .widgetURL(URL(string: "sada://nowplaying"))
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                WidgetArtwork(file: snap.current?.artworkFile, cornerRadius: 12)
                    .frame(width: 110, height: 110)
                    .shadow(radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 6)
                    WidgetControls(isPlaying: snap.isPlaying, size: 20)
                }
            }
            Text("UP NEXT").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
            if snap.upNext.isEmpty {
                Text("Nothing queued").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                VStack(spacing: 8) {
                    ForEach(snap.upNext.prefix(4)) { item in
                        HStack(spacing: 10) {
                            WidgetArtwork(file: item.artworkFile, cornerRadius: 5)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).font(.subheadline).lineLimit(1)
                                Text(item.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .containerBackground(for: .widget) { WidgetBackdrop(file: snap.current?.artworkFile) }
        .widgetURL(URL(string: "sada://nowplaying"))
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                Text(artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: snap.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.plain)
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "sada://nowplaying"))
    }

    private var circular: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: snap.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }
}
