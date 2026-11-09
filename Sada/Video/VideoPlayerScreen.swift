import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Presentation (UIKit, so the player opens in landscape and can rotate)

final class PlayerHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

@MainActor
enum VideoPresenter {
    private static weak var host: UIViewController?

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive && $0 is UIWindowScene } as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
    }

    private static func topController() -> UIViewController? {
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    static func present(_ item: VideoItem) {
        guard host == nil, let top = topController() else { return }
        PlayerEngine.shared.pause()
        AppDelegate.orientationMask = .allButUpsideDown
        let accent = Color(hex: UserDefaults.standard.string(forKey: ThemeKeys.accent) ?? AccentPreset.pink.rawValue)
        let screen = VideoPlayerScreen(item: item) { dismiss() }
            .environment(LibraryStore.shared)
            .environment(PlayerEngine.shared)
            .environment(AppRouter.shared)
            .tint(accent)
        let vc = PlayerHostingController(rootView: AnyView(screen))
        vc.view.backgroundColor = .black
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
        host = vc
        top.present(vc, animated: true) {
            vc.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
    }

    static func dismiss() {
        guard let vc = host else { return }
        host = nil
        AppDelegate.orientationMask = .portrait
        var root = scene?.keyWindow?.rootViewController
        while let r = root {
            r.setNeedsUpdateOfSupportedInterfaceOrientations()
            root = r.presentedViewController
        }
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        vc.dismiss(animated: true)
        AppRouter.shared.playingVideo = nil
    }
}

// MARK: - Player screen (Netflix / Apple TV style)

struct VideoPlayerScreen: View {
    var onClose: () -> Void
    @State private var controller: VideoPlayerController
    @State private var showControls = true
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?
    @State private var hud: HUD?
    @State private var dragMode: DragMode?
    @State private var dragStartValue: Double = 0
    @State private var seekPreview: Double?
    @State private var dismissOffset: CGFloat = 0
    @State private var showSubtitleSheet = false
    @State private var showEpisodes = false
    @State private var boosted = false
    @State private var tapFeedback: (side: Int, id: Int)?
    @AppStorage("subtitle.size") private var subtitleSize: Double = 20
    @AppStorage("subtitle.background") private var subtitleBackground = true
    @AppStorage("subtitle.yellow") private var subtitleYellow = false
    @AppStorage("video.skip") private var skipSeconds = 10
    @AppStorage("video.autoNext") private var autoNext = true
    @AppStorage("video.gesture.brightness") private var brightnessGesture = true
    @AppStorage("video.gesture.volume") private var volumeGesture = true
    @AppStorage("video.gesture.seek") private var seekGesture = true

    enum DragMode { case seek, volume, brightness, dismiss }
    enum HUD: Equatable { case volume(Float), brightness(CGFloat), text(String) }

    init(item: VideoItem, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _controller = State(initialValue: VideoPlayerController(item: item))
    }

    private var isLandscape: Bool { controller.viewSize.width > controller.viewSize.height }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoCanvas(controller: controller)
                    .ignoresSafeArea()
                HiddenVolumeView().frame(width: 1, height: 1)

                subtitles(geo: geo)
                gestureLayer(geo: geo)

                if let hud { hudView(hud).transition(.opacity.combined(with: .scale(scale: 0.9))) }

                if let feedback = tapFeedback {
                    skipRipple(side: feedback.side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: feedback.side < 0 ? .leading : .trailing)
                        .padding(.horizontal, isLandscape ? 90 : 40)
                        .transition(.opacity)
                        .id(feedback.id)
                }

                if boosted {
                    Label("2× Speed", systemImage: "forward.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
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
                if let resumed = controller.resumedFrom, showControls, !locked { resumeToast(resumed) }
            }
            .offset(y: dismissOffset)
            .opacity(1 - min(dismissOffset / 500, 0.5))
            .animation(.easeInOut(duration: 0.2), value: showControls)
            .animation(.easeInOut(duration: 0.15), value: hud)
            .onAppear { controller.viewSize = geo.size }
            .onChange(of: geo.size) { _, s in
                controller.viewSize = s
                controller.setGravity(controller.gravity)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { scheduleHide() }
        .onDisappear { controller.stop() }
        .sheet(isPresented: $showSubtitleSheet) {
            SubtitleSheet(controller: controller).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodesSheet(current: controller.item) { ep in
                showEpisodes = false
                controller.load(ep)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func close() {
        controller.stop()
        onClose()
    }

    // MARK: Subtitles

    @ViewBuilder private func subtitles(geo: GeometryProxy) -> some View {
        if let text = controller.subtitleText {
            Text(text)
                .font(.system(size: subtitleSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(subtitleYellow ? Color.yellow : .white)
                .shadow(color: .black, radius: 2)
                .shadow(color: .black.opacity(0.9), radius: 4)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(subtitleBackground ? 0.45 : 0), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: geo.size.width * 0.82)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, showControls && !locked ? (isLandscape ? 120 : 170) : 36)
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
                controller.skip(by: Double(side * skipSeconds))
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
                    controller.setGravity(.resizeAspectFill)
                } else if value.magnification < 0.92 {
                    controller.setGravity(.resizeAspect)
                }
                flash(.text(controller.gravityName))
            }, isEnabled: !locked)
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 12, perform: {
                guard !locked, controller.isPlaying else { return }
                boosted = true
                controller.setBoost(true)
            }, onPressingChanged: { pressing in
                if !pressing && boosted {
                    boosted = false
                    controller.setBoost(false)
                }
            })
    }

    /// Left side: brightness · right side: volume · middle: swipe down to close · sideways: seek.
    private func dragGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                if dragMode == nil {
                    let x = g.startLocation.x / max(geo.size.width, 1)
                    if abs(g.translation.width) > abs(g.translation.height) {
                        guard seekGesture else { return }
                        dragMode = .seek
                        dragStartValue = controller.currentTime
                    } else if x < 0.33 {
                        guard brightnessGesture else { return }
                        dragMode = .brightness
                        dragStartValue = Double(DeviceControls.brightness)
                    } else if x > 0.67 {
                        guard volumeGesture else { return }
                        dragMode = .volume
                        dragStartValue = Double(DeviceControls.volume)
                    } else if g.translation.height > 0 {
                        dragMode = .dismiss
                    }
                }
                switch dragMode {
                case .seek:
                    let span = min(max(controller.duration, 60), 180)
                    let target = max(0, min(controller.duration, dragStartValue + Double(g.translation.width / geo.size.width) * span))
                    seekPreview = target
                    let delta = Int(target - dragStartValue)
                    hud = .text("\(delta >= 0 ? "+" : "−")\(formatTime(Double(abs(delta))))   \(formatTime(target)) / \(formatTime(controller.duration))")
                case .brightness:
                    let v = dragStartValue - Double(g.translation.height / (geo.size.height * 0.75))
                    DeviceControls.brightness = CGFloat(v)
                    hud = .brightness(DeviceControls.brightness)
                case .volume:
                    let v = dragStartValue - Double(g.translation.height / (geo.size.height * 0.75))
                    DeviceControls.volume = Float(v)
                    hud = .volume(Float(max(0, min(1, v))))
                case .dismiss:
                    dismissOffset = max(0, g.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { g in
                switch dragMode {
                case .seek:
                    if let target = seekPreview { controller.seek(to: target) }
                case .dismiss:
                    if g.translation.height > 130 || g.predictedEndTranslation.height > 400 {
                        close()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dismissOffset = 0 }
                    }
                default:
                    break
                }
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
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, controller.isPlaying, !showSubtitleSheet, !showEpisodes else { return }
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
                Text(t).font(.headline.monospacedDigit()).padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .foregroundStyle(.white)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Image(systemName: side < 0 ? "gobackward.\(skipSeconds)" : "goforward.\(skipSeconds)").font(.system(size: 34, weight: .semibold))
            Text(side < 0 ? "−\(skipSeconds)s" : "+\(skipSeconds)s").font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(24)
        .glassEffect(.regular, in: Circle())
    }

    // MARK: Controls

    private func controls(geo: GeometryProxy) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack(spacing: 14) {
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                    Spacer()
                    VStack(spacing: 2) {
                        Text(controller.item.kind == .episode ? (controller.item.showName ?? controller.item.title) : controller.item.title)
                            .font(.headline).lineLimit(1)
                        if let code = controller.item.episodeCode {
                            Text("\(code) · \(controller.item.displayTitle)").font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                    Spacer()
                    if controller.pip != nil && controller.backend == .apple {
                        Button { controller.pip?.startPictureInPicture() } label: {
                            Image(systemName: "pip.enter").font(.headline).frame(width: 44, height: 44)
                        }
                        .glassEffect(.regular.interactive(), in: Circle())
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, isLandscape ? 44 : 18)
                .padding(.top, isLandscape ? 18 : 60)

                Spacer()

                // Center transport
                HStack(spacing: isLandscape ? 72 : 44) {
                    transportButton("gobackward.\(skipSeconds)", size: 30) { controller.skip(by: -Double(skipSeconds)) }
                    Button {
                        controller.togglePlay()
                        scheduleHide()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 86, height: 86)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                    transportButton("goforward.\(skipSeconds)", size: 30) { controller.skip(by: Double(skipSeconds)) }
                }

                Spacer()

                // Bottom: scrubber + Netflix-style action row
                VStack(spacing: 12) {
                    VideoScrubber(controller: controller, onScrub: { scheduleHide() })
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isLandscape ? 30 : 22) {
                            Menu {
                                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                                    Button {
                                        controller.setRate(Float(r))
                                    } label: {
                                        if Float(r) == controller.rate { Label("\(r, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%g")×") }
                                    }
                                }
                            } label: {
                                actionLabel("Speed (\(String(format: "%g", controller.rate))×)", icon: "gauge.with.dots.needle.67percent")
                            }
                            Button { withAnimation { locked = true; showControls = false } } label: {
                                actionLabel("Lock", icon: "lock.open")
                            }
                            if controller.item.kind == .episode {
                                Button { showEpisodes = true; hideTask?.cancel() } label: {
                                    actionLabel("Episodes", icon: "rectangle.stack")
                                }
                            }
                            Button { showSubtitleSheet = true; hideTask?.cancel() } label: {
                                actionLabel("Audio & Subtitles", icon: controller.activeSubtitleName == nil ? "captions.bubble" : "captions.bubble.fill")
                            }
                            Button { controller.cycleGravity(); flash(.text(controller.gravityName)) } label: {
                                actionLabel(controller.gravityName, icon: "arrow.up.left.and.arrow.down.right")
                            }
                            if let next = VideoStore.shared.nextEpisode(after: controller.item) {
                                Button { controller.load(next) } label: {
                                    actionLabel("Next Ep.", icon: "forward.end.fill")
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, isLandscape ? 44 : 18)
                .padding(.bottom, isLandscape ? 18 : 44)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: icon).font(.system(size: size, weight: .medium)).frame(width: 64, height: 64)
        }
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .fixedSize()
    }

    private var lockOverlay: some View {
        Button {
            withAnimation { locked = false; showControls = true }
            scheduleHide()
        } label: {
            Label("Tap to Unlock", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, isLandscape ? 20 : 60)
        .opacity(showControls ? 1 : 0.4)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Close") { close() }.adaptiveButton()
        }
        .foregroundStyle(.white)
        .padding(30)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var endCard: some View {
        if let next = VideoStore.shared.nextEpisode(after: controller.item) {
            UpNextCard(next: next, autoPlay: autoNext) { controller.load(next) } onClose: { close() }
        }
    }

    private func resumeToast(_ seconds: Double) -> some View {
        HStack(spacing: 12) {
            Text("Resumed from \(formatTime(seconds))").font(.footnote.weight(.medium))
            Button("Start Over") { controller.seek(to: 0) }.font(.footnote.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, isLandscape ? 80 : 130)
    }
}

/// Episode list inside the player (Netflix "Episodes").
struct EpisodesSheet: View {
    let current: VideoItem
    var onPick: (VideoItem) -> Void
    @State private var season = 1

    var body: some View {
        NavigationStack {
            if let show = VideoStore.shared.show(id: current.showKey) {
                ScrollView {
                    VStack(spacing: 12) {
                        if show.seasons.count > 1 {
                            Picker("Season", selection: $season) {
                                ForEach(show.seasons, id: \.self) { Text("Season \($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(show.episodes.filter { ($0.season ?? 1) == season }) { ep in
                            Button { onPick(ep) } label: {
                                EpisodeRow(episode: ep)
                                    .padding(8)
                                    .background(ep.id == current.id ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                                in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .navigationTitle(show.name)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { season = current.season ?? 1 }
            }
        }
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
    var autoPlay = true
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
                Button { onPlay() } label: { Label(autoPlay ? "Play in \(countdown)" : "Play", systemImage: "play.fill") }
                    .adaptiveButton(prominent: true)
                Button("Close", action: onClose).adaptiveButton()
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(28)
        .task {
            guard autoPlay else { return }
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
            onPlay()
        }
    }
}
