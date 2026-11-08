import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit
import WidgetKit

enum RepeatMode: Int, Codable {
    case off, all, one
}

@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    private(set) var queue: [Track] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var currentArtwork: UIImage?
    private(set) var palette: [Color] = ColorExtractor.fallback
    private(set) var lyrics: LyricsDocument?
    private(set) var lyricsLoading = false
    private(set) var currentLyricIndex: Int?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var duration: Double {
        if let d = currentItem?.duration, d.isNumeric, d.seconds > 0 { return d.seconds }
        return current?.duration ?? 0
    }
    var currentLyricText: String? {
        guard let i = currentLyricIndex, let lines = lyrics?.lines, lines.indices.contains(i) else { return nil }
        return lines[i].text
    }
    var nextLyricText: String? {
        guard let i = currentLyricIndex, let lines = lyrics?.lines, lines.indices.contains(i + 1) else { return nil }
        return lines[i + 1].text
    }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var queuedNextItem: AVPlayerItem?
    @ObservationIgnored private var queuedNextIndex: Int?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var lastPersist = Date.distantPast

    private init() {}

    // MARK: - Setup

    func configure() {
        guard !configured else { return }
        configured = true

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        player.actionAtItemEnd = .advance

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayingState() }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemDidFinish(item) }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            else { return }
            MainActor.assumeIsolated { self?.player.play() }
        }

        setupRemoteCommands()
        restoreState()
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    // MARK: - Public controls

    func play(_ tracks: [Track], startAt: Int = 0, shuffle shuffled: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        configure()
        let start = min(max(startAt, 0), tracks.count - 1)
        originalQueue = tracks
        if let shuffled { shuffle = shuffled }
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: start)
            rest.shuffle()
            queue = [first] + rest
            index = 0
        } else {
            queue = tracks
            index = start
        }
        loadCurrent(autoplay: true)
    }

    func shuffleAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        play(tracks, startAt: Int.random(in: 0..<tracks.count), shuffle: true)
    }

    func play() {
        guard current != nil else {
            shuffleAll(LibraryStore.shared.tracks)
            return
        }
        if currentItem == nil {
            loadCurrent(autoplay: true, at: currentTime)
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
    }

    func pause() {
        player.pause()
        persistState()
    }

    func togglePlayPause() {
        configure()
        isPlaying ? pause() : play()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoplay: true)
        } else if repeatMode != .off {
            index = 0
            loadCurrent(autoplay: true)
        } else {
            index = 0
            loadCurrent(autoplay: false)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if index > 0 {
            index -= 1
        } else if repeatMode == .all {
            index = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(duration - 0.25, 0)))
        currentTime = target
        if currentItem == nil {
            pendingSeek = target
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateLyricIndex()
        updateNowPlayingInfo()
        LiveActivityManager.shared.sync(engine: self, force: true)
    }

    /// Jump to an item in "Up Next" (offset 0 = the next song).
    func jumpToUpNext(_ offset: Int) {
        let target = index + 1 + offset
        guard queue.indices.contains(target) else { return }
        index = target
        loadCurrent(autoplay: true)
    }

    func playNext(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.insert(track, at: index + 1)
        originalQueue.append(track)
        enqueueNext()
        publishExternalState()
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
        enqueueNext()
        publishExternalState()
    }

    func removeFromUpNext(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        let removedIDs = absolute.compactMap { queue.indices.contains($0) ? queue[$0].id : nil }
        queue.remove(atOffsets: absolute)
        for id in removedIDs {
            if let i = originalQueue.firstIndex(where: { $0.id == id }) { originalQueue.remove(at: i) }
        }
        enqueueNext()
        publishExternalState()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var next = upNext
        next.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + next
        enqueueNext()
        publishExternalState()
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [cur] + rest
            index = 0
        } else if !originalQueue.isEmpty {
            queue = originalQueue
            index = originalQueue.firstIndex(where: { $0.id == cur.id }) ?? 0
        }
        enqueueNext()
        publishExternalState()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        enqueueNext()
    }

    // MARK: - Item management

    private func loadCurrent(autoplay: Bool, at time: Double = 0) {
        player.removeAllItems()
        queuedNextItem = nil
        queuedNextIndex = nil
        itemStatusObservation = nil

        guard let track = current else {
            currentItem = nil
            isPlaying = false
            trackDidChange()
            return
        }

        let item = AVPlayerItem(url: LibraryStore.shared.url(for: track))
        currentItem = item
        player.insert(item, after: nil)
        currentTime = time
        pendingSeek = time > 0 ? time : nil
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.applyPendingSeek() }
        }
        enqueueNext()

        if autoplay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        trackDidChange()
    }

    private func applyPendingSeek() {
        guard let target = pendingSeek, currentItem != nil else { return }
        pendingSeek = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Pre-queues the following song in AVQueuePlayer for gapless playback.
    private func enqueueNext() {
        for item in player.items() where item !== currentItem {
            player.remove(item)
        }
        queuedNextItem = nil
        queuedNextIndex = nil
        guard repeatMode != .one, let cur = currentItem else { return }

        let nextIndex: Int?
        if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all, !queue.isEmpty {
            nextIndex = 0
        } else {
            nextIndex = nil
        }
        guard let n = nextIndex else { return }

        let item = AVPlayerItem(url: LibraryStore.shared.url(for: queue[n]))
        if player.canInsert(item, after: cur) {
            player.insert(item, after: cur)
            queuedNextItem = item
            queuedNextIndex = n
        }
    }

    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, item === currentItem else { return }
        if let t = current { LibraryStore.shared.markPlayed(t.id) }

        if repeatMode == .one {
            loadCurrent(autoplay: true)
            return
        }
        if let n = queuedNextIndex, let nextItem = queuedNextItem {
            index = n
            currentItem = nextItem
            queuedNextItem = nil
            queuedNextIndex = nil
            currentTime = 0
            itemStatusObservation = nil
            enqueueNext()
            trackDidChange()
        } else {
            // End of the queue: stop on the first song, like Apple Music.
            index = 0
            loadCurrent(autoplay: false)
        }
    }

    // MARK: - State updates

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, pendingSeek == nil else { return }
        currentTime = seconds
        updateLyricIndex()
        if Date().timeIntervalSince(lastPersist) > 10 { persistState() }
    }

    private func syncPlayingState() {
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlayingInfo()
        publishExternalState()
    }

    private func trackDidChange() {
        if let t = current {
            currentArtwork = LibraryStore.shared.artworkImage(for: t)
        } else {
            currentArtwork = nil
        }
        palette = ColorExtractor.palette(from: currentArtwork)
        loadLyrics()
        updateNowPlayingInfo()
        publishExternalState()
        persistState()
    }

    func artworkDidChange(for ids: Set<String>) {
        guard let t = current, ids.contains(t.id), let fresh = LibraryStore.shared.track(id: t.id) else { return }
        queue[index] = fresh
        currentArtwork = LibraryStore.shared.artworkImage(for: fresh)
        palette = ColorExtractor.palette(from: currentArtwork)
        updateNowPlayingInfo()
        publishExternalState()
    }

    // MARK: - Lyrics

    private func loadLyrics() {
        lyrics = nil
        currentLyricIndex = nil
        lyricsLoading = false
        guard let t = current else { return }
        let fresh = LibraryStore.shared.track(id: t.id) ?? t
        if let text = LibraryStore.shared.lyricsText(for: fresh) {
            lyrics = LRCParser.parse(text)
            updateLyricIndex()
            return
        }
        guard AppSettings.autoLyrics else { return }
        fetchLyrics(force: false)
    }

    func fetchLyrics(force: Bool) {
        guard let t = current else { return }
        let id = t.id
        lyricsLoading = true
        Task {
            let text = await MetadataEnricher.shared.fetchLyrics(for: t, force: force)
            guard self.current?.id == id else { return }
            self.lyricsLoading = false
            if let text {
                self.lyrics = LRCParser.parse(text)
                self.updateLyricIndex()
                self.publishExternalState()
            }
        }
    }

    private func updateLyricIndex() {
        guard let doc = lyrics, doc.isSynced else {
            if currentLyricIndex != nil { currentLyricIndex = nil }
            return
        }
        let t = currentTime + 0.25
        var found: Int?
        for line in doc.lines {
            guard let time = line.time else { continue }
            if time <= t { found = line.id } else { break }
        }
        if found != currentLyricIndex {
            currentLyricIndex = found
            LiveActivityManager.shared.sync(engine: self)
        }
    }

    // MARK: - System integration

    private func updateNowPlayingInfo() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyAlbumTitle: t.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let image = currentArtwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Pushes state to the widgets and the optional lyrics Live Activity.
    func publishExternalState() {
        let library = LibraryStore.shared
        func item(_ t: Track) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(id: t.id, title: t.title, artist: t.displayArtist,
                                artworkFile: SharedArtwork.export(t, library: library))
        }
        let snapshot = WidgetSnapshot(
            current: current.map(item),
            isPlaying: isPlaying,
            upNext: upNext.prefix(4).map(item),
            updatedAt: Date()
        )
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlayingWidget")
        LiveActivityManager.shared.sync(engine: self, force: true)
    }

    // MARK: - Persistence

    func persistState() {
        lastPersist = Date()
        let d = UserDefaults.standard
        d.set(queue.map(\.id), forKey: "player.queue")
        d.set(originalQueue.map(\.id), forKey: "player.originalQueue")
        d.set(index, forKey: "player.index")
        d.set(currentTime, forKey: "player.time")
        d.set(shuffle, forKey: "player.shuffle")
        d.set(repeatMode.rawValue, forKey: "player.repeat")
    }

    private func restoreState() {
        let d = UserDefaults.standard
        let library = LibraryStore.shared
        let ids = d.stringArray(forKey: "player.queue") ?? []
        let restored = ids.compactMap { library.track(id: $0) }
        guard !restored.isEmpty else { return }
        queue = restored
        originalQueue = (d.stringArray(forKey: "player.originalQueue") ?? []).compactMap { library.track(id: $0) }
        if originalQueue.isEmpty { originalQueue = restored }
        index = min(max(d.integer(forKey: "player.index"), 0), restored.count - 1)
        currentTime = d.double(forKey: "player.time")
        shuffle = d.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: d.integer(forKey: "player.repeat")) ?? .off
        // The item is created lazily on first play so launch stays fast.
        currentArtwork = current.flatMap { library.artworkImage(for: $0) }
        palette = ColorExtractor.palette(from: currentArtwork)
        loadLyrics()
        updateNowPlayingInfo()
    }
}

/// Copies small artwork thumbnails into the App Group so widgets / Live Activities can show them.
enum SharedArtwork {
    @MainActor
    static func export(_ track: Track, library: LibraryStore) -> String? {
        guard track.hasArtwork, let dir = SharedStore.artworkDirectory else { return nil }
        let name = "\(track.id).jpg"
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        guard let image = ImageUtil.downsample(url: library.artworkFileURL(track.id), maxPixel: 360),
              let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        try? data.write(to: dest, options: .atomic)
        prune(dir)
        return name
    }

    static func invalidate(_ id: String) {
        guard let dir = SharedStore.artworkDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg"))
    }

    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 60 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(files.count - 40) { try? fm.removeItem(at: url) }
    }
}
