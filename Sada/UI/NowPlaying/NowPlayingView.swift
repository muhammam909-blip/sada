import SwiftUI

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .artwork

    var body: some View {
        ZStack {
            NowPlayingBackground(colors: player.palette, animate: player.isPlaying)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Button { dismiss() } label: {
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                switch mode {
                case .artwork:
                    BigArtwork(image: player.currentArtwork, seed: player.current?.albumID ?? "", isPlaying: player.isPlaying)
                        .frame(maxHeight: .infinity)
                        .onTapGesture(count: 2) { player.togglePlayPause() }
                    TitleRow()
                        .padding(.bottom, 18)
                case .lyrics:
                    CompactHeader { withAnimation(.spring(duration: 0.45)) { mode = .artwork } }
                    LyricsView()
                        .frame(maxHeight: .infinity)
                case .queue:
                    CompactHeader { withAnimation(.spring(duration: 0.45)) { mode = .artwork } }
                    QueueView()
                        .frame(maxHeight: .infinity)
                }

                ScrubberView()
                    .padding(.top, 8)
                TransportControls()
                    .padding(.vertical, 22)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption)
                    SystemVolumeSlider().frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill").font(.caption)
                }
                .foregroundStyle(.white.opacity(0.6))
                BottomBar(mode: $mode)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
        .onChange(of: player.current == nil) { _, empty in if empty { dismiss() } }
    }
}

// MARK: - Pieces

struct BigArtwork: View {
    let image: UIImage?
    let seed: String
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder(seed: seed)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(isPlaying ? 0.45 : 0.25), radius: isPlaying ? 30 : 14, y: isPlaying ? 18 : 8)
            .scaleEffect(isPlaying ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, 12)
    }
}

struct TitleRow: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(player.current?.displayArtist ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
            if let track = player.current {
                Menu {
                    TrackMenuItems(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.15), in: Circle())
                }
            }
        }
    }
}

struct CompactHeader: View {
    var onTap: () -> Void
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = player.currentArtwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder(seed: player.current?.albumID ?? "")
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                Text(player.current?.displayArtist ?? "").foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct ScrubberView: View {
    @Environment(PlayerEngine.self) private var player
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = min(dragValue ?? player.currentTime, duration)
        let active = dragValue != nil

        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(active ? 1 : 0.75))
                        .frame(width: max(0, width * value / duration))
                }
                .frame(height: active ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in dragValue = min(max(g.location.x / width, 0), 1) * duration }
                        .onEnded { _ in
                            if let v = dragValue { player.seek(to: v) }
                            dragValue = nil
                        }
                )
                .animation(.spring(duration: 0.25), value: active)
            }
            .frame(height: 22)
            .scaleEffect(x: active ? 1.03 : 1, y: 1)

            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(duration - value, 0)))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(active ? 0.9 : 0.55))
        }
        .sensoryFeedback(.selection, trigger: active)
    }
}

struct TransportControls: View {
    @Environment(PlayerEngine.self) private var player
    @State private var backTaps = 0
    @State private var forwardTaps = 0

    var body: some View {
        HStack {
            Spacer()
            Button {
                backTaps += 1
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.bounce.down, value: backTaps)
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 70, height: 70)
            }
            Spacer()
            Button {
                forwardTaps += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.bounce.down, value: forwardTaps)
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
    }
}

struct BottomBar: View {
    @Binding var mode: NowPlayingView.Mode

    var body: some View {
        HStack {
            toggle(.lyrics, on: "quote.bubble.fill", off: "quote.bubble")
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            toggle(.queue, on: "list.bullet.circle.fill", off: "list.bullet")
        }
        .font(.title3)
        .padding(.horizontal, 24)
    }

    private func toggle(_ target: NowPlayingView.Mode, on: String, off: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.45)) { mode = mode == target ? .artwork : target }
        } label: {
            Image(systemName: mode == target ? on : off)
                .frame(width: 44, height: 44)
                .foregroundStyle(.white.opacity(mode == target ? 1 : 0.65))
                .background {
                    if mode == target { Circle().fill(.white.opacity(0.18)) }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Slowly moving mesh gradient built from the artwork colours (Apple Music style).
struct NowPlayingBackground: View {
    let colors: [Color]
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: points(t),
                colors: colors.count == 9 ? colors : ColorExtractor.fallback
            )
        }
        .overlay(Color.black.opacity(0.22))
        .animation(.easeInOut(duration: 0.9), value: colors)
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        let a = Float(sin(t * 0.45)) * 0.18
        let b = Float(cos(t * 0.37)) * 0.18
        let c = Float(sin(t * 0.29 + 1.3)) * 0.12
        return [
            SIMD2<Float>(0, 0), SIMD2<Float>(0.5 + c, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0.5 + a), SIMD2<Float>(0.5 + b, 0.5 + a), SIMD2<Float>(1, 0.5 - b),
            SIMD2<Float>(0, 1), SIMD2<Float>(0.5 - c, 1), SIMD2<Float>(1, 1),
        ]
    }
}
