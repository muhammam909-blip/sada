import SwiftUI

struct LyricsView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let doc = player.lyrics, !doc.lines.isEmpty {
            let alignment: HorizontalAlignment = doc.isRTL ? .trailing : .leading
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: alignment, spacing: doc.isSynced ? 26 : 14) {
                        Color.clear.frame(height: 30)
                        ForEach(doc.lines) { line in
                            LyricLineView(
                                text: line.text,
                                synced: doc.isSynced,
                                active: line.id == player.currentLyricIndex,
                                passed: (player.currentLyricIndex ?? -1) > line.id,
                                rtl: doc.isRTL
                            )
                            .id(line.id)
                            .onTapGesture {
                                if let time = line.time { player.seek(to: time) }
                            }
                        }
                        Color.clear.frame(height: 220)
                    }
                    .frame(maxWidth: .infinity, alignment: doc.isRTL ? .trailing : .leading)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onAppear {
                    if let i = player.currentLyricIndex { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
                .onChange(of: player.currentLyricIndex) { _, i in
                    guard let i else { return }
                    withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
                        proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.3))
                    }
                }
            }
        } else if player.lyricsLoading {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Looking for lyrics…").foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.6))
                Text("No lyrics found").font(.headline)
                Button("Search Again") { player.fetchLyrics(force: true) }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LyricLineView: View {
    let text: String
    let synced: Bool
    let active: Bool
    let passed: Bool
    let rtl: Bool

    var body: some View {
        let isBreak = text.isEmpty
        Text(isBreak ? "•  •  •" : text)
            .font(synced ? .system(size: 30, weight: .bold) : .system(size: 22, weight: .semibold))
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .foregroundStyle(.white.opacity(!synced || active ? 1 : (passed ? 0.32 : 0.42)))
            .blur(radius: synced && !active ? 0.8 : 0)
            .scaleEffect(synced && active ? 1.0 : (synced ? 0.96 : 1), anchor: rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .animation(.easeOut(duration: 0.35), value: active)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .contentShape(Rectangle())
    }
}

struct QueueView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Playing Next").font(.headline)
                Spacer()
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 40, height: 32)
                        .background(player.shuffle ? Color.white.opacity(0.3) : Color.white.opacity(0.1), in: Capsule())
                }
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .frame(width: 40, height: 32)
                        .background(player.repeatMode != .off ? Color.white.opacity(0.3) : Color.white.opacity(0.1), in: Capsule())
                }
            }
            .buttonStyle(.plain)

            if player.upNext.isEmpty {
                Text(player.repeatMode == .all ? "The queue will repeat." : "Nothing up next.")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                        HStack(spacing: 12) {
                            ArtworkView(track: track, cornerRadius: 5, pixelSize: 132)
                                .frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1)
                                Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jumpToUpNext(offset) }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.15))
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
    }
}
