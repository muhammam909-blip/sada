import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Continue Watching widget

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let snapshot: VideoWidgetSnapshot
}

struct ContinueWatchingProvider: TimelineProvider {
    private static let sample = VideoWidgetSnapshot(items: [
        .init(id: "a", title: "The Sopranos", subtitle: "S01E02 · 23:00 left", progress: 0.6, imageFile: nil),
        .init(id: "b", title: "City of God", subtitle: "1:12:00 left", progress: 0.3, imageFile: nil),
    ])

    func placeholder(in context: Context) -> ContinueWatchingEntry { .init(date: .now, snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        let s = SharedStore.loadVideos()
        completion(.init(date: .now, snapshot: (context.isPreview && s.items.isEmpty) ? Self.sample : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, snapshot: SharedStore.loadVideos())], policy: .never))
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatchingWidget", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Jump back into your movie or episode.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct WidgetStill: View {
    let file: String?

    var body: some View {
        Group {
            if let url = SharedStore.artworkURL(file), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.6)))
            }
        }
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Color.pink).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

struct ContinueWatchingView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    private func link(_ id: String) -> URL? { URL(string: "sada://video/\(id)") }

    var body: some View {
        if let first = entry.snapshot.items.first {
            switch family {
            case .systemLarge: large
            default: hero(first)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle").font(.title)
                Text("Nothing to continue").font(.headline)
                Text("Start a movie or episode in MHM.").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { Color.black }
        }
    }

    private func hero(_ item: VideoWidgetSnapshot.Item) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.caption2)
                    Text("CONTINUE").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.8))
                Text(item.title).font(family == .systemSmall ? .subheadline.weight(.bold) : .headline).lineLimit(2)
                Text(item.subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                ProgressLine(value: item.progress).padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .containerBackground(for: .widget) { WidgetStill(file: item.imageFile) }
        .widgetURL(link(item.id))
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching").font(.headline).foregroundStyle(.white)
            ForEach(entry.snapshot.items.prefix(4)) { item in
                Link(destination: link(item.id) ?? URL(string: "sada://")!) {
                    HStack(spacing: 12) {
                        WidgetStill(file: item.imageFile)
                            .frame(width: 110, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(item.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            ProgressLine(value: item.progress)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .containerBackground(for: .widget) { Color(white: 0.08) }
    }
}

// MARK: - Control Center / Lock Screen / Action button controls

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hammam.sada.control.playpause") {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("MHM Play/Pause", systemImage: "playpause.fill")
            }
        }
        .displayName("MHM Play/Pause")
        .description("Play or pause music in MHM.")
    }
}

struct NextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hammam.sada.control.next") {
            ControlWidgetButton(action: NextTrackIntent()) {
                Label("MHM Next Song", systemImage: "forward.fill")
            }
        }
        .displayName("MHM Next Song")
    }
}

struct ShuffleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hammam.sada.control.shuffle") {
            ControlWidgetButton(action: ShuffleLibraryIntent()) {
                Label("MHM Shuffle", systemImage: "shuffle")
            }
        }
        .displayName("MHM Shuffle All")
        .description("Shuffle your whole library — great on the Action button.")
    }
}
