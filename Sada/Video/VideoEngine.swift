import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(VLCKit)
import VLCKit
#endif

struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

enum VideoEngineChoice: String, CaseIterable, Identifiable {
    case auto = "Automatic", vlc = "Always VLC"
    var id: String { rawValue }
}

/// Plays a video with Apple's player (MP4/MOV, supports Picture in Picture) or VLC (everything else).
/// In Automatic mode a file the Apple player can't open falls back to VLC.
@MainActor
@Observable
final class VideoPlayerController {
    enum Backend { case apple, vlc }

    let avPlayer = AVPlayer()
    let vlc = VLCMediaPlayer()

    private(set) var backend: Backend = .apple
    private(set) var item: VideoItem
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var gravity: AVLayerVideoGravity = .resizeAspect
    private(set) var cues: [SubtitleCue] = []
    private(set) var subtitleText: String?
    var subtitleDelay: Double = 0 { didSet { applySubtitleDelay() } }
    private(set) var activeSubtitleName: String?
    private(set) var subtitleTracks: [TrackOption] = []
    private(set) var audioTracks: [TrackOption] = []
    private(set) var selectedSubtitleTrack: Int?
    private(set) var selectedAudioTrack: Int?
    private(set) var failureMessage: String?
    private(set) var ended = false
    private(set) var resumedFrom: Double?
    var pip: AVPictureInPictureController?
    var viewSize: CGSize = .zero

    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var vlcResumeDone = false

    init(item: VideoItem) {
        self.item = item
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.backend == .apple else { return }
                self.tick(t.seconds)
            }
        }
        rateObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.backend == .apple else { return }
                self.isPlaying = playing
            }
        }
        load(item)
    }

    // MARK: Loading

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
        subtitleTracks = []
        audioTracks = []
        selectedSubtitleTrack = nil
        selectedAudioTrack = nil
        currentTime = 0
        duration = video.duration
        vlcResumeDone = false

        guard let url = VideoStore.shared.url(for: video) else {
            failureMessage = "The file isn't available."
            return
        }
        currentURL = url
        let ext = url.pathExtension.lowercased()
        let choice = VideoEngineChoice(rawValue: UserDefaults.standard.string(forKey: "video.engine") ?? "") ?? .auto
        if choice == .auto && VideoStore.nativeExtensions.contains(ext) {
            startApple(url)
        } else {
            startVLC(url)
        }
        autoLoadSubtitles()
    }

    private func startApple(_ url: URL) {
        backend = .apple
        vlc.stop()
        pollTask?.cancel()
        let playerItem = AVPlayerItem(url: url)
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            Task { @MainActor in self?.appleStatusChanged(status) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnd() }
        }
        avPlayer.replaceCurrentItem(with: playerItem)
    }

    private func startVLC(_ url: URL) {
        backend = .vlc
        avPlayer.replaceCurrentItem(with: nil)
        pip = nil
        let media = VLCMedia(url: url)
        media.addOption(":file-caching=800")
        vlc.media = media
        vlc.play()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollVLC()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func appleStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            guard !isReady, let current = avPlayer.currentItem else { return }
            isReady = true
            let d = current.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            Task { await loadAppleTracks(current.asset) }
            resumeIfNeeded()
            avPlayer.play()
            avPlayer.rate = rate
        case .failed:
            // Apple's player can't decode this file: hand it to VLC.
            if let url = currentURL { startVLC(url) }
        default:
            break
        }
    }

    private func loadAppleTracks(_ asset: AVAsset) async {
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            legibleGroup = group
            subtitleTracks = group.options.enumerated().map { TrackOption(id: $0.offset, name: $0.element.displayName) }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audibleGroup = group
            audioTracks = group.options.enumerated().map { TrackOption(id: $0.offset, name: $0.element.displayName) }
            if let sel = avPlayer.currentItem?.currentMediaSelection.selectedMediaOption(in: group) {
                selectedAudioTrack = group.options.firstIndex(of: sel)
            }
        }
        if !cues.isEmpty, let g = legibleGroup { avPlayer.currentItem?.select(nil, in: g) }
    }

    private func pollVLC() {
        guard backend == .vlc else { return }
        let t = Double(vlc.time.intValue) / 1000
        let len = Double(vlc.media?.length.intValue ?? 0) / 1000
        if len > 0 { duration = len }
        isPlaying = vlc.isPlaying

        switch vlc.state {
        case .error:
            failureMessage = "This video couldn't be played."
            return
        case .ended:
            if !ended { didEnd() }
            return
        default:
            break
        }

        if !isReady, vlc.isPlaying {
            isReady = true
            vlc.rate = rate
        }
        if isReady {
            if !vlcResumeDone, len > 0 {
                vlcResumeDone = true
                resumeIfNeeded()
            }
            refreshVLCTracks()
        }
        tick(t)
    }

    private func refreshVLCTracks() {
        let subNames = (vlc.videoSubTitlesNames as? [String]) ?? []
        let subIndexes = ((vlc.videoSubTitlesIndexes as? [NSNumber]) ?? []).map(\.intValue)
        let subs = zip(subIndexes, subNames).filter { $0.0 >= 0 }.map { TrackOption(id: $0.0, name: $0.1) }
        if subs != subtitleTracks {
            subtitleTracks = subs
            // Our own subtitle file wins over the built-in track.
            if !cues.isEmpty { vlc.currentVideoSubTitleIndex = -1 }
        }
        let current = Int(vlc.currentVideoSubTitleIndex)
        selectedSubtitleTrack = (cues.isEmpty && current >= 0) ? current : nil

        let audioNames = (vlc.audioTrackNames as? [String]) ?? []
        let audioIndexes = ((vlc.audioTrackIndexes as? [NSNumber]) ?? []).map(\.intValue)
        let audio = zip(audioIndexes, audioNames).filter { $0.0 >= 0 }.map { TrackOption(id: $0.0, name: $0.1) }
        if audio != audioTracks { audioTracks = audio }
        selectedAudioTrack = Int(vlc.currentAudioTrackIndex)
    }

    private func resumeIfNeeded() {
        guard UserDefaults.standard.object(forKey: "video.resume") as? Bool ?? true else { return }
        if item.position > 15, duration == 0 || item.position < duration - 30 {
            resumedFrom = item.position
            seek(to: item.position)
        }
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
        isPlaying = false
        VideoStore.shared.updateProgress(item.id, position: duration, duration: duration)
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying {
            backend == .apple ? avPlayer.pause() : vlc.pause()
        } else {
            if ended { ended = false; seek(to: 0) }
            if backend == .apple {
                avPlayer.play()
                avPlayer.rate = rate
            } else {
                vlc.play()
            }
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(duration - 1, 0)))
        currentTime = target
        if backend == .apple {
            avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            vlc.time = VLCTime(int: Int32(target * 1000))
        }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ r: Float) {
        rate = r
        applyRate(r)
    }

    /// Hold-to-2× uses this without changing the chosen speed.
    func setBoost(_ on: Bool) { applyRate(on ? 2 : rate) }

    private func applyRate(_ r: Float) {
        if backend == .apple {
            if isPlaying { avPlayer.rate = r }
        } else {
            vlc.rate = r
        }
    }

    func setGravity(_ g: AVLayerVideoGravity) {
        gravity = g
        guard backend == .vlc else { return }
        let w = max(Int(viewSize.width.rounded()), 1)
        let h = max(Int(viewSize.height.rounded()), 1)
        switch g {
        case .resizeAspectFill:
            vlc.videoAspectRatio = nil
            vlc.videoCropGeometry = strdup("\(w):\(h)")
        case .resize:
            vlc.videoCropGeometry = nil
            vlc.videoAspectRatio = strdup("\(w):\(h)")
        default:
            vlc.videoCropGeometry = nil
            vlc.videoAspectRatio = nil
        }
    }

    func cycleGravity() {
        switch gravity {
        case .resizeAspect: setGravity(.resizeAspectFill)
        case .resizeAspectFill: setGravity(.resize)
        default: setGravity(.resizeAspect)
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
        selectedSubtitleTrack = nil
        if backend == .apple {
            if let g = legibleGroup { avPlayer.currentItem?.select(nil, in: g) }
        } else {
            vlc.currentVideoSubTitleIndex = -1
        }
    }

    func selectSubtitleTrack(_ track: TrackOption?) {
        cues = []
        subtitleText = nil
        activeSubtitleName = track?.name
        selectedSubtitleTrack = track?.id
        if backend == .apple {
            guard let g = legibleGroup else { return }
            let option = track.flatMap { t in g.options.indices.contains(t.id) ? g.options[t.id] : nil }
            avPlayer.currentItem?.select(option, in: g)
        } else {
            vlc.currentVideoSubTitleIndex = Int32(track?.id ?? -1)
        }
        applySubtitleDelay()
    }

    func subtitlesOff() { selectSubtitleTrack(nil) }

    func selectAudioTrack(_ track: TrackOption) {
        selectedAudioTrack = track.id
        if backend == .apple {
            guard let g = audibleGroup, g.options.indices.contains(track.id) else { return }
            avPlayer.currentItem?.select(g.options[track.id], in: g)
        } else {
            vlc.currentAudioTrackIndex = Int32(track.id)
        }
    }

    private func applySubtitleDelay() {
        // Our own subtitle files use subtitleDelay directly in tick(); VLC's built-in tracks need it too.
        if backend == .vlc { vlc.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000) }
    }

    // MARK: Lifecycle

    func saveProgress() {
        lastSave = Date()
        guard isReady, currentTime > 5 else { return }
        VideoStore.shared.updateProgress(item.id, position: currentTime, duration: duration)
    }

    func stop() {
        saveProgress()
        avPlayer.pause()
        vlc.stop()
        pollTask?.cancel()
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

/// Draws whichever engine is active.
struct VideoCanvas: View {
    let controller: VideoPlayerController

    var body: some View {
        switch controller.backend {
        case .apple: VideoSurface(controller: controller)
        case .vlc: VLCSurface(player: controller.vlc)
        }
    }
}

struct VLCSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
