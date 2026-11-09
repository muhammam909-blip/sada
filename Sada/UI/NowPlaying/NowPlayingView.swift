import SwiftUI

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .artwork
    @State private var dragY: CGFloat = 0
    @State private var swipeX: CGFloat = 0

    /// Swipe down anywhere on the artwork / header to close (like Spotify & Apple Music).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                guard abs(g.translation.height) > abs(g.translation.width) else { return }
                dragY = max(0, g.translation.height)
            }
            .onEnded { g in
                if g.translation.height > 140 || g.predictedEndTranslation.height > 420 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                }
            }
    }

    /// Swipe the artwork left = next song, right = previous.
    private var skipDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { g in
                guard abs(g.translation.width) > abs(g.translation.height) else {
                    dragY = max(0, g.translation.height)
                    return
                }
                swipeX = g.translation.width
            }
            .onEnded { g in
                if dragY > 0 {
                    if g.translation.height > 140 || g.predictedEndTranslation.height > 420 { dismiss() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                    return
                }
                let w = g.translation.width
                guard abs(w) > 90 || abs(g.predictedEndTranslation.width) > 300 else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { swipeX = 0 }
                    return
                }
                let forward = w < 0
                withAnimation(.easeIn(duration: 0.15)) { swipeX = forward ? -500 : 500 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    if forward { player.next() } else { player.previous() }
                    swipeX = forward ? 500 : -500
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { swipeX = 0 }
                }
            }
    }

    var body: some View {
        ZStack {
            NowPlayingBackdrop()
                .ignoresSafeArea()
                .opacity(1 - min(dragY / 600, 0.4))

            VStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .gesture(dismissDrag)

                switch mode {
                case .artwork:
                    BigArtwork(image: player.currentArtwork, seed: player.current?.albumID ?? "", isPlaying: player.isPlaying)
                        .offset(x: swipeX)
                        .rotationEffect(.degrees(Double(swipeX) / 40))
                        .opacity(1 - min(abs(swipeX) / 700, 0.5))
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.togglePlayPause() }
                        .gesture(skipDrag)
                        .overlay {
                            if player.isResolving {
                                ProgressView().controlSize(.large).tint(.white)
                                    .padding(20).background(.ultraThinMaterial, in: Circle())
                            }
                        }
                    TitleRow()
                        .padding(.bottom, 18)
                        .id(player.current?.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                        .animation(.smooth(duration: 0.35), value: player.current?.id)
                case .lyrics:
                    CompactHeader { withAnimation(.spring(duration: 0.45)) { mode = .artwork } }
                        .gesture(dismissDrag)
                    LyricsView()
                        .frame(maxHeight: .infinity)
                case .queue:
                    CompactHeader { withAnimation(.spring(duration: 0.45)) { mode = .artwork } }
                        .gesture(dismissDrag)
                    QueueView()
                        .frame(maxHeight: .infinity)
                }

                ScrubberView()
                    .padding(.top, 8)
                TransportControls()
                    .padding(.vertical, 22)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption)
                    SystemVolumeSlider().frame(maxWidth: .infinity).frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill").font(.caption)
                }
                .foregroundStyle(.white.opacity(0.6))
                BottomBar(mode: $mode)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
            .foregroundStyle(.white)
            .containerRelativeFrame(.horizontal) // keep the player exactly screen-wide
        }
        .offset(y: dragY)
        .scaleEffect(1 - min(dragY / 3000, 0.06))
        .clipShape(DragCardShape(radius: dragY > 0 ? 44 : 0, active: dragY > 0))
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
        .onChange(of: player.current == nil) { _, empty in if empty { dismiss() } }
    }
}

/// Clips nothing at rest (so the player fills the whole screen, safe areas included);
/// while dragging it becomes a rounded card.
struct DragCardShape: Shape {
    var radius: CGFloat
    var active: Bool

    func path(in rect: CGRect) -> Path {
        let expanded = rect.insetBy(dx: active ? 0 : -400, dy: active ? -80 : -400)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: expanded)
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
            if let track = player.current, track.isOnline {
                OnlineDownloadButton(song: OnlineTrack.song(from: track))
            } else if let track = player.current {
                let favorite = LibraryStore.shared.track(id: track.id)?.isFavorite ?? false
                Button {
                    LibraryStore.shared.toggleFavorite(track.id)
                } label: {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .font(.headline)
                        .foregroundStyle(favorite ? Color.pink : .white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.15), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: favorite)
                Menu {
                    TrackMenuItems(track: track, showQueueActions: false)
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

/// Download button shown on the player while streaming an online song.
struct OnlineDownloadButton: View {
    let song: OnlineSong
    @State private var downloads = DownloadManager.shared

    var body: some View {
        let state = downloads.states[song.id]
        Button {
            downloads.download(song)
        } label: {
            HStack(spacing: 6) {
                switch state {
                case .downloading(let p):
                    ProgressView(value: p).progressViewStyle(.circular).tint(.white).controlSize(.small)
                    Text("\(Int(p * 100))%")
                case .preparing, .finishing:
                    ProgressView().tint(.white).controlSize(.small)
                    Text("Saving")
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                    Text("Downloaded")
                case .failed:
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                case nil:
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state?.isActive == true || state == .done)
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

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack {
            toggle(.lyrics, on: "quote.bubble.fill", off: "quote.bubble")
            Spacer()
            sleepMenu
            Spacer()
            toggle(.queue, on: "list.bullet.circle.fill", off: "list.bullet")
        }
        .font(.title3)
        .padding(.horizontal, 24)
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepTimerActive {
                Button(role: .destructive) { player.setSleepTimer(minutes: nil) } label: { Label("Turn Off Timer", systemImage: "moon.zzz") }
            }
            Button("End of Current Song") { player.sleepAtEndOfCurrentTrack() }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) Minutes") { player.setSleepTimer(minutes: m) }
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: player.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                if let end = player.sleepTimerEnd {
                    Text(end, style: .timer)
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                } else if player.sleepAtEndOfTrack {
                    Text("song end").font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 54, height: 44)
            .foregroundStyle(.white.opacity(player.sleepTimerActive ? 1 : 0.65))
        }
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

/// Background chosen in Settings › Appearance.
struct NowPlayingBackdrop: View {
    @Environment(PlayerEngine.self) private var player
    @AppStorage(ThemeKeys.npBackground) private var style: NowPlayingBackgroundStyle = .animated

    var body: some View {
        switch style {
        case .animated:
            NowPlayingBackground(colors: player.palette, animate: player.isPlaying)
        case .blurred:
            ZStack {
                Color.black
                if let image = player.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60)
                        .scaleEffect(1.4)
                        .opacity(0.9)
                }
                Color.black.opacity(0.35)
            }
            .animation(.easeInOut(duration: 0.6), value: player.current?.id)
        case .black:
            Color.black
        }
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
