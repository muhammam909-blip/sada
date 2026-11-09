import AVFoundation
import AVKit
import MediaPlayer
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class VideoPlayerController {
    let player = AVPlayer()
    private(set) var item: VideoItem
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    var gravity: AVLayerVideoGravity = .resizeAspect
    private(set) var cues: [SubtitleCue] = []
    private(set) var subtitleText: String?
    var subtitleDelay: Double = 0
    private(set) var activeSubtitleName: String?
    private(set) var legibleOptions: [AVMediaSelectionOption] = []
    private(set) var audibleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedLegible: AVMediaSelectionOption?
    private(set) var selectedAudible: AVMediaSelectionOption?
    private(set) var failureMessage: String?
    private(set) var ended = false
    private(set) var resumedFrom: Double?
    var pip: AVPictureInPictureController?

    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSave = Date.distantPast

    init(item: VideoItem) {
        self.item = item
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        load(item)
    }

    func load(_ video: VideoItem) {
        saveProgress()
        item = video
        isReady = false
        ended = false
        failureMessage = nil
        cues = []
        subtitleText = nil
        activeSubtitleName = nil
        resumedFrom = nil
        legibleOptions = []
        audibleOptions = []
        currentTime = 0
        duration = video.duration

        guard let url = VideoStore.shared.url(for: video) else {
            failureMessage = "The file isn't available."
            return
        }
        let playerItem = AVPlayerItem(url: url)
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            Task { @MainActor in self?.statusChanged(status) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnd() }
        }
        player.replaceCurrentItem(with: playerItem)
        autoLoadSubtitles()
    }

    private func statusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            guard !isReady, let current = player.currentItem else { return }
            isReady = true
            let d = current.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            Task { await loadMediaGroups(current.asset) }
            if item.position > 15, duration == 0 || item.position < duration - 30 {
                resumedFrom = item.position
                player.seek(to: CMTime(seconds: item.position, preferredTimescale: 600))
            }
            player.play()
            player.rate = rate
        case .failed:
            let ext = (item.relativePath as NSString).pathExtension.uppercased()
            failureMessage = VideoStore.nativeExtensions.contains(ext.lowercased())
                ? "This video couldn't be played."
                : "\(ext) files need the VLC/MPV engine, which is coming in the next update. MP4, M4V and MOV play now."
        default: break
        }
    }

    private func loadMediaGroups(_ asset: AVAsset) async {
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            legibleGroup = group
            legibleOptions = group.options
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audibleGroup = group
            audibleOptions = group.options
            selectedAudible = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
        }
        // Turn off embedded subtitles if we already loaded an external file.
        if !cues.isEmpty, let g = legibleGroup { player.currentItem?.select(nil, in: g) }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if !cues.isEmpty {
            subtitleText = SubtitleParser.cue(at: t - subtitleDelay, in: cues)?.text
        }
        if Date().timeIntervalSince(lastSave) > 5 { saveProgress() }
    }

    private func didEnd() {
        ended = true
        VideoStore.shared.updateProgress(item.id, position: duration, duration: duration)
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if ended { seek(to: 0); ended = false }
            player.play()
            player.rate = rate
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(duration - 1, 0)))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
    }

    func cycleGravity() {
        switch gravity {
        case .resizeAspect: gravity = .resizeAspectFill
        case .resizeAspectFill: gravity = .resize
        default: gravity = .resizeAspect
        }
    }

    var gravityName: String {
        switch gravity {
        case .resizeAspectFill: "Fill"
        case .resize: "Stretch"
        default: "Fit"
        }
    }

    // MARK: Subtitles & audio

    private func autoLoadSubtitles() {
        let files = VideoStore.shared.subtitleFiles(for: item)
        let preferred = UserDefaults.standard.string(forKey: "subtitle.language") ?? "ar"
        let pick = files.first { $0.lastPathComponent.lowercased().contains(".\(preferred)") } ?? files.first
        if let pick { loadExternal(pick) }
    }

    func loadExternal(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        cues = SubtitleParser.parse(SubtitleParser.decode(data))
        activeSubtitleName = url.deletingPathExtension().lastPathComponent
        selectedLegible = nil
        if let g = legibleGroup { player.currentItem?.select(nil, in: g) }
    }

    func selectLegible(_ option: AVMediaSelectionOption?) {
        cues = []
        subtitleText = nil
        activeSubtitleName = option?.displayName
        selectedLegible = option
        if let g = legibleGroup { player.currentItem?.select(option, in: g) }
    }

    func subtitlesOff() {
        selectLegible(nil)
        activeSubtitleName = nil
    }

    func selectAudible(_ option: AVMediaSelectionOption) {
        selectedAudible = option
        if let g = audibleGroup { player.currentItem?.select(option, in: g) }
    }

    // MARK: Lifecycle

    func saveProgress() {
        lastSave = Date()
        guard isReady, currentTime > 5 else { return }
        VideoStore.shared.updateProgress(item.id, position: currentTime, duration: duration)
    }

    func stop() {
        saveProgress()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

// MARK: - Video surface (AVPlayerLayer + Picture in Picture)

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let controller: VideoPlayerController

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = controller.player
        view.playerLayer.videoGravity = controller.gravity
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            DispatchQueue.main.async { controller.pip = pip }
        }
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.videoGravity != controller.gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            view.playerLayer.videoGravity = controller.gravity
            CATransaction.commit()
        }
    }
}

// MARK: - System volume & brightness

@MainActor
enum DeviceControls {
    static weak var volumeSlider: UISlider?

    static var volume: Float {
        get { volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume }
        set { volumeSlider?.value = max(0, min(1, newValue)) }
    }

    static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    static var brightness: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = max(0, min(1, newValue)) }
    }
}

/// An invisible MPVolumeView: lets gestures change the volume and hides the system volume HUD.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        view.alpha = 0.0001
        DispatchQueue.main.async {
            DeviceControls.volumeSlider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Orientation

final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

@MainActor
enum Orientation {
    static func allow(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        var vc = scene.keyWindow?.rootViewController
        while let current = vc {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { _ in }
    }
}
