import AVFoundation
import AVKit
import SwiftUI

struct VideoPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller: VideoPlayerController
    @State private var showControls = true
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?
    @State private var hud: HUD?
    @State private var dragMode: DragMode?
    @State private var dragStartValue: Double = 0
    @State private var seekPreview: Double?
    @State private var showSubtitleSheet = false
    @State private var boosted = false
    @State private var tapFeedback: (side: Int, id: Int)?
    @AppStorage("subtitle.size") private var subtitleSize: Double = 20

    enum DragMode { case seek, volume, brightness }
    enum HUD: Equatable {
        case volume(Float), brightness(CGFloat), text(String)
    }

    init(item: VideoItem) {
        _controller = State(initialValue: VideoPlayerController(item: item))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(controller: controller)
                    .ignoresSafeArea()
                HiddenVolumeView().frame(width: 1, height: 1)

                subtitles(geo: geo)

                gestureLayer(geo: geo)

                if let hud { hudView(hud).transition(.opacity.combined(with: .scale(scale: 0.9))) }

                if let feedback = tapFeedback {
                    skipRipple(side: feedback.side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: feedback.side < 0 ? .leading : .trailing)
                        .padding(.horizontal, 60)
                        .transition(.opacity)
                        .id(feedback.id)
                }

                if boosted {
                    Label("2× speed", systemImage: "forward.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 24)
                }

                if locked {
                    lockOverlay
                } else if showControls {
                    controls(geo: geo).transition(.opacity)
                }

                if let message = controller.failureMessage { failure(message) }
                if controller.ended { endCard }
                if let resumed = controller.resumedFrom, showControls { resumeToast(resumed) }
            }
            .animation(.easeInOut(duration: 0.2), value: showControls)
            .animation(.easeInOut(duration: 0.15), value: hud)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            PlayerEngine.shared.pause()
            Orientation.allow(.allButUpsideDown, prefer: .landscapeRight)
            scheduleHide()
        }
        .onDisappear {
            controller.stop()
            Orientation.allow(.portrait, prefer: .portrait)
        }
        .sheet(isPresented: $showSubtitleSheet) {
            SubtitleSheet(controller: controller)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Subtitles

    @ViewBuilder private func subtitles(geo: GeometryProxy) -> some View {
        if let text = controller.subtitleText {
            Text(text)
                .font(.system(size: subtitleSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .shadow(color: .black.opacity(0.9), radius: 4)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: geo.size.width * 0.8)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, showControls && !locked ? 96 : 28)
                .animation(.easeOut(duration: 0.2), value: showControls)
                .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    private func gestureLayer(geo: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                guard !locked else { return }
                let side = location.x < geo.size.width / 2 ? -1 : 1
                controller.skip(by: Double(side) * 10)
                withAnimation { tapFeedback = (side, (tapFeedback?.id ?? 0) + 1) }
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation { tapFeedback = nil }
                }
            }
            .onTapGesture(count: 1) {
                withAnimation { showControls.toggle() }
                if showControls { scheduleHide() }
            }
            .gesture(dragGesture(geo: geo), isEnabled: !locked)
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                if value.magnification > 1.08 {
                    controller.gravity = .resizeAspectFill
                } else if value.magnification < 0.92 {
                    controller.gravity = .resizeAspect
                }
                flash(.text(controller.gravityName))
            }, isEnabled: !locked)
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 12, perform: {
                guard !locked, controller.isPlaying else { return }
                boosted = true
                controller.player.rate = 2
            }, onPressingChanged: { pressing in
                if !pressing && boosted {
                    boosted = false
                    controller.player.rate = controller.rate
                }
            })
    }

    private func dragGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                if dragMode == nil {
                    if abs(g.translation.width) > abs(g.translation.height) {
                        dragMode = .seek
                        dragStartValue = controller.currentTime
                    } else if g.startLocation.x < geo.size.width / 2 {
                        dragMode = .brightness
                        dragStartValue = Double(DeviceControls.brightness)
                    } else {
                        dragMode = .volume
                        dragStartValue = Double(DeviceControls.volume)
                    }
                }
                switch dragMode {
                case .seek:
                    // Full screen width ≈ 3 minutes (or the whole video if shorter).
                    let span = min(max(controller.duration, 60), 180)
                    let target = max(0, min(controller.duration, dragStartValue + Double(g.translation.width / geo.size.width) * span))
                    seekPreview = target
                    let delta = Int(target - dragStartValue)
                    hud = .text("\(delta >= 0 ? "+" : "−")\(formatTime(Double(abs(delta))))   \(formatTime(target)) / \(formatTime(controller.duration))")
                case .brightness:
                    let v = dragStartValue - Double(g.translation.height / (geo.size.height * 0.8))
                    DeviceControls.brightness = CGFloat(v)
                    hud = .brightness(DeviceControls.brightness)
                case .volume:
                    let v = dragStartValue - Double(g.translation.height / (geo.size.height * 0.8))
                    DeviceControls.volume = Float(v)
                    hud = .volume(Float(max(0, min(1, v))))
                case nil: break
                }
            }
            .onEnded { _ in
                if dragMode == .seek, let target = seekPreview { controller.seek(to: target) }
                dragMode = nil
                seekPreview = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if dragMode == nil { hud = nil }
                }
            }
    }

    private func flash(_ value: HUD) {
        hud = value
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if hud == value { hud = nil }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, controller.isPlaying, !showSubtitleSheet else { return }
            withAnimation { showControls = false }
        }
    }

    // MARK: HUDs

    @ViewBuilder private func hudView(_ hud: HUD) -> some View {
        Group {
            switch hud {
            case .volume(let v):
                levelHUD(icon: v == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", value: Double(v))
            case .brightness(let b):
                levelHUD(icon: "sun.max.fill", value: Double(b))
            case .text(let t):
                Text(t).font(.headline.monospacedDigit())
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func levelHUD(icon: String, value: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 26)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: g.size.width * max(0, min(1, value)))
                }
            }
            .frame(width: 150, height: 6)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func skipRipple(side: Int) -> some View {
        VStack(spacing: 4) {
            Image(systemName: side < 0 ? "gobackward.10" : "goforward.10").font(.system(size: 34, weight: .semibold))
            Text(side < 0 ? "−10s" : "+10s").font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.white.opacity(0.15), in: Circle())
    }

    // MARK: Controls

    private func controls(geo: GeometryProxy) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack(spacing: 18) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(controller.item.kind == .episode ? (controller.item.showName ?? controller.item.title) : controller.item.title)
                            .font(.headline).lineLimit(1)
                        if let code = controller.item.episodeCode {
                            Text("\(code) · \(controller.item.displayTitle)").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    if controller.pip != nil {
                        Button { controller.pip?.startPictureInPicture() } label: { Image(systemName: "pip.enter") }
                    }
                    Button { showSubtitleSheet = true; hideTask?.cancel() } label: {
                        Image(systemName: controller.activeSubtitleName == nil ? "captions.bubble" : "captions.bubble.fill")
                    }
                    Button { withAnimation { locked = true; showControls = false } } label: { Image(systemName: "lock.open") }
                }
                .font(.title3)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer()

                // Center transport
                HStack(spacing: 56) {
                    Button { controller.skip(by: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                    Button { controller.togglePlay(); scheduleHide() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 54))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 70)
                    }
                    Button { controller.skip(by: 10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
                }

                Spacer()

                // Bottom bar
                VStack(spacing: 10) {
                    VideoScrubber(controller: controller, onScrub: { scheduleHide() })
                    HStack(spacing: 22) {
                        Menu {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                                Button { controller.setRate(Float(r)) } label: {
                                    if Float(r) == controller.rate { Label("\(r, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%g")×") }
                                }
                            }
                        } label: {
                            Label("\(controller.rate, specifier: "%g")×", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        Button { controller.cycleGravity(); flash(.text(controller.gravityName)) } label: {
                            Label(controller.gravityName, systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        Spacer()
                        if let next = VideoStore.shared.nextEpisode(after: controller.item) {
                            Button { controller.load(next) } label: {
                                Label("Next Episode", systemImage: "forward.end.fill")
                            }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }

    private var lockOverlay: some View {
        Button {
            withAnimation { locked = false; showControls = true }
            scheduleHide()
        } label: {
            Label("Unlock", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .opacity(showControls ? 1 : 0.35)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Close") { dismiss() }.adaptiveButton()
        }
        .foregroundStyle(.white)
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var endCard: some View {
        if let next = VideoStore.shared.nextEpisode(after: controller.item) {
            UpNextCard(next: next) { controller.load(next) } onClose: { dismiss() }
        }
    }

    private func resumeToast(_ seconds: Double) -> some View {
        HStack(spacing: 12) {
            Text("Resumed from \(formatTime(seconds))").font(.footnote.weight(.medium))
            Button("Start Over") { controller.seek(to: 0) }
                .font(.footnote.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 70)
    }
}

struct VideoScrubber: View {
    let controller: VideoPlayerController
    var onScrub: () -> Void
    @State private var drag: Double?

    var body: some View {
        let duration = max(controller.duration, 1)
        let value = drag ?? controller.currentTime
        HStack(spacing: 12) {
            Text(formatTime(value)).font(.caption.monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.tint).frame(width: geo.size.width * min(value / duration, 1))
                    Circle().fill(.white)
                        .frame(width: drag == nil ? 12 : 18, height: drag == nil ? 12 : 18)
                        .offset(x: geo.size.width * min(value / duration, 1) - (drag == nil ? 6 : 9))
                }
                .frame(height: drag == nil ? 4 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in drag = min(max(g.location.x / geo.size.width, 0), 1) * duration; onScrub() }
                    .onEnded { _ in if let d = drag { controller.seek(to: d) }; drag = nil })
                .animation(.snappy(duration: 0.2), value: drag == nil)
            }
            .frame(height: 24)
            Text("-" + formatTime(max(duration - value, 0))).font(.caption.monospacedDigit())
        }
    }
}

struct UpNextCard: View {
    let next: VideoItem
    var onPlay: () -> Void
    var onClose: () -> Void
    @State private var countdown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 14) {
                PosterImage(file: next.stillFile ?? next.backdropFile ?? next.posterFile, aspect: 16 / 9)
                    .frame(width: 160)
                VStack(alignment: .leading, spacing: 4) {
                    Text(next.episodeCode ?? "").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(next.displayTitle).font(.headline).lineLimit(2)
                }
            }
            HStack {
                Button { onPlay() } label: { Label("Play in \(countdown)", systemImage: "play.fill") }
                    .adaptiveButton(prominent: true)
                Button("Close", action: onClose).adaptiveButton()
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(28)
        .task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
            onPlay()
        }
    }
}
