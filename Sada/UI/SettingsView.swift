import SwiftUI

/// iOS-Settings-style rows: coloured rounded icon + title + current value.
struct SettingsRow<Destination: View>: View {
    let title: String
    let icon: String
    let color: Color
    var value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true
    @AppStorage("video.engine") private var engine = VideoEngineChoice.auto.rawValue

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MHM").font(.title3.bold())
                            Text("\(library.tracks.count) songs · \(VideoStore.shared.videos.count) videos")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    SettingsRow(title: "Appearance", icon: "paintbrush.fill", color: .indigo, value: appearance.rawValue) {
                        AppearanceSettingsView()
                    }
                    SettingsRow(title: "Tabs", icon: "rectangle.split.3x1.fill", color: .gray) { TabSettingsView() }
                }

                Section("Media") {
                    SettingsRow(title: "Music Player", icon: "music.note", color: .pink,
                                value: EqualizerSettings.shared.enabled ? "EQ: \(EqualizerSettings.shared.presetName)" : nil) {
                        MusicSettingsView()
                    }
                    SettingsRow(title: "Online", icon: "dot.radiowaves.left.and.right", color: .orange, value: onlineEnabled ? "On" : "Off") {
                        OnlineSettingsView()
                    }
                    SettingsRow(title: "Videos & Player", icon: "film.fill", color: .blue,
                                value: engine == VideoEngineChoice.vlc.rawValue ? "VLC" : "Auto") {
                        VideoSettingsView()
                    }
                }

                Section("Library") {
                    SettingsRow(title: "Library & Folders", icon: "folder.fill", color: .teal, value: "\(library.linkedFolders.count) linked") {
                        LibrarySettingsView()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Widgets", value: AppGroup.containerURL == nil ? "Storage unavailable" : "Ready")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage(ThemeKeys.accent) private var accentHex = AccentPreset.pink.rawValue
    @AppStorage(ThemeKeys.npBackground) private var npBackground: NowPlayingBackgroundStyle = .animated
    @AppStorage(ThemeKeys.lyricsSize) private var lyricsSize: Double = 1.0

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Player Background", selection: $npBackground) {
                    ForEach(NowPlayingBackgroundStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section("Accent Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                    ForEach(AccentPreset.allCases) { preset in
                        Circle()
                            .fill(preset.color.gradient)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if accentHex.uppercased() == preset.rawValue {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { accentHex = preset.rawValue }
                    }
                    ColorPicker("", selection: Binding(get: { Color(hex: accentHex) }, set: { accentHex = $0.hexString }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
                .padding(.vertical, 6)
            }

            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Lyrics Text Size", value: "\(Int(lyricsSize * 100))%")
                    Slider(value: $lyricsSize, in: 0.7...1.4, step: 0.05)
                }
            }

            Section {
                LabeledContent("Design", value: "Liquid Glass")
            } footer: {
                Text("MHM uses the iOS 26 Liquid Glass design.")
            }
        }
        .navigationTitle("Appearance")
    }
}

// MARK: - Music player

struct MusicSettingsView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("fadeSeconds") private var fadeSeconds: Double = 0
    @AppStorage("lyricsInDynamicIsland") private var lyricsInDynamicIsland = false
    @AppStorage("autoArtwork") private var autoArtwork = true
    @AppStorage("autoLyrics") private var autoLyrics = true

    var body: some View {
        Form {
            Section("Sound") {
                NavigationLink {
                    EqualizerView()
                } label: {
                    LabeledContent("Equalizer", value: EqualizerSettings.shared.enabled ? EqualizerSettings.shared.presetName : "Off")
                }
                VStack(alignment: .leading) {
                    LabeledContent("Fade Between Songs", value: fadeSeconds == 0 ? "Off" : "\(Int(fadeSeconds)) s")
                    Slider(value: $fadeSeconds, in: 0...10, step: 1)
                }
            }
            Section {
                Toggle("Live Lyrics in Dynamic Island", isOn: $lyricsInDynamicIsland)
                    .onChange(of: lyricsInDynamicIsland) { _, _ in PlayerEngine.shared.publishExternalState() }
            } header: {
                Text("Dynamic Island")
            } footer: {
                Text("Shows the current lyric line next to the camera. iOS keeps its own Now Playing bubble too.")
            }
            Section {
                Toggle("Find Missing Artwork", isOn: $autoArtwork)
                Toggle("Find Missing Lyrics", isOn: $autoLyrics)
                Button("Retry Songs Without Artwork or Lyrics") { library.retryMissing() }
                if let status = library.enrichmentStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Artwork & Lyrics")
            } footer: {
                Text("Artwork from Deezer and Apple Music, lyrics from LRCLIB.")
            }
        }
        .navigationTitle("Music Player")
    }
}

// MARK: - Online

struct OnlineSettingsView: View {
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true
    @AppStorage("online.region") private var region = "EG"
    @AppStorage("recentOnlineSearches") private var recentSearches = ""

    static let regions: [(code: String, name: String)] = [
        ("EG", "Egypt"), ("SA", "Saudi Arabia"), ("AE", "UAE"), ("KW", "Kuwait"), ("MA", "Morocco"),
        ("US", "United States"), ("GB", "United Kingdom"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Online Music", isOn: $onlineEnabled)
            } footer: {
                Text("Streaming, online search, radio and recommendations. Turn off to use MHM fully offline.")
            }
            if onlineEnabled {
                Section("Recommendations") {
                    Picker("Trending Region", selection: $region) {
                        ForEach(Self.regions, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: region) { _, _ in Task { await OnlineFeed.shared.refreshIfNeeded(force: true) } }
                    Button("Refresh Recommendations Now") {
                        Task { await OnlineFeed.shared.refreshIfNeeded(force: true) }
                    }
                }
                Section("History") {
                    Button("Clear Recent Searches", role: .destructive) { recentSearches = "" }
                    Button("Clear Recently Streamed", role: .destructive) { OnlineFeed.shared.clearHistory() }
                }
                Section {
                    LabeledContent("Download quality", value: "Best available (AAC)")
                } footer: {
                    Text("Downloads are saved to On My iPhone › Music › Downloads with artwork and lyrics.")
                }
            }
        }
        .navigationTitle("Online")
    }
}

/// Folders tab settings: folders plus a shortcut to everything else.
struct FoldersSettingsPage: View {
    var body: some View {
        LibrarySettingsView()
            .safeAreaInset(edge: .bottom) {
                NavigationLink {
                    MusicSettingsView()
                } label: {
                    Label("Music Player Settings", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveButton()
                .padding()
            }
    }
}

// MARK: - Library

struct LibrarySettingsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var importMode: ImportMode?

    var body: some View {
        Form {
            Section {
                ForEach(library.linkedFolders) { folder in
                    HStack {
                        Image(systemName: library.isFolderAvailable(folder) ? "folder.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(library.isFolderAvailable(folder) ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                        Text(folder.name)
                        Spacer()
                        Text("\(library.tracks.filter { $0.sourceID == folder.id }.count)").foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { library.unlinkFolder(library.linkedFolders[i]) }
                }
                Button { importMode = .linkFolder } label: { Label("Link a Folder", systemImage: "link") }
            } header: {
                Text("Linked Folders")
            } footer: {
                Text("Played in place from their app (like nPlayer), no extra space. Swipe to unlink — files are not deleted.")
            }

            Section("Library") {
                LabeledContent("Songs", value: "\(library.tracks.count)")
                LabeledContent("Albums", value: "\(library.albums.count)")
                LabeledContent("Artists", value: "\(library.artists.count)")
                LabeledContent("Videos", value: "\(VideoStore.shared.videos.count)")
                Button {
                    Task {
                        await library.rescan()
                        await VideoStore.shared.rescan()
                    }
                } label: {
                    HStack {
                        Text("Rescan Everything")
                        if library.isScanning { Spacer(); ProgressView() }
                    }
                }
            }
        }
        .navigationTitle("Library & Folders")
        .addMusicImporter($importMode)
    }
}
