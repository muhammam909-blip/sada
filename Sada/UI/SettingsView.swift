import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage("autoArtwork") private var autoArtwork = true
    @AppStorage("autoLyrics") private var autoLyrics = true
    @AppStorage("lyricsInDynamicIsland") private var lyricsInDynamicIsland = false
    @State private var importMode: ImportMode?
    @AppStorage(ThemeKeys.accent) private var accentHex = AccentPreset.pink.rawValue
    @AppStorage(ThemeKeys.glass) private var glass = true
    @AppStorage(ThemeKeys.npBackground) private var npBackground: NowPlayingBackgroundStyle = .animated
    @AppStorage(ThemeKeys.lyricsSize) private var lyricsSize: Double = 1.0
    @AppStorage("fadeSeconds") private var fadeSeconds: Double = 0

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent Color")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(AccentPreset.allCases) { preset in
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if accentHex.uppercased() == preset.rawValue {
                                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                            }
                                        }
                                        .onTapGesture { accentHex = preset.rawValue }
                                }
                                ColorPicker("", selection: Binding(
                                    get: { Color(hex: accentHex) },
                                    set: { accentHex = $0.hexString }
                                ), supportsOpacity: false)
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Toggle("Liquid Glass Buttons", isOn: $glass)

                    Picker("Player Background", selection: $npBackground) {
                        ForEach(NowPlayingBackgroundStyle.allCases) { Text($0.rawValue).tag($0) }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Lyrics Size")
                            Spacer()
                            Text("\(Int(lyricsSize * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $lyricsSize, in: 0.7...1.4, step: 0.05)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("With Liquid Glass off, MHM's own buttons use the classic solid style. The tab bar and menus are drawn by iOS itself and keep their glass look.")
                }

                Section {
                    NavigationLink {
                        EqualizerView()
                    } label: {
                        LabeledContent("Equalizer", value: EqualizerSettings.shared.enabled ? EqualizerSettings.shared.presetName : "Off")
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Fade Between Songs")
                            Spacer()
                            Text(fadeSeconds == 0 ? "Off" : "\(Int(fadeSeconds)) s").foregroundStyle(.secondary)
                        }
                        Slider(value: $fadeSeconds, in: 0...10, step: 1)
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Fade lowers the volume at the end of a song and brings it back up at the start of the next one.")
                }

                Section {
                    ForEach(library.linkedFolders) { folder in
                        HStack {
                            Image(systemName: library.isFolderAvailable(folder) ? "folder.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(library.isFolderAvailable(folder) ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                            Text(folder.name)
                            Spacer()
                            Text("\(library.tracks.filter { $0.sourceID == folder.id }.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { library.unlinkFolder(library.linkedFolders[i]) }
                    }
                    Button { importMode = .linkFolder } label: { Label("Link a Folder", systemImage: "link") }
                } header: {
                    Text("Linked Folders")
                } footer: {
                    Text("Linked folders are played in place from their app (like nPlayer) and take no extra space. Swipe to unlink — files are not deleted.")
                }

                Section {
                    Toggle("Find Missing Artwork", isOn: $autoArtwork)
                    Toggle("Find Missing Lyrics", isOn: $autoLyrics)
                    Button("Retry Songs Without Artwork or Lyrics") { library.retryMissing() }
                    if let status = library.enrichmentStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Automatic Metadata")
                } footer: {
                    Text("Artwork: Deezer and Apple Music. Lyrics: LRCLIB (synced when available). For a song that still has nothing, use Find Artwork… / Find Lyrics… from its menu.")
                }

                Section {
                    Toggle("Live Lyrics in Dynamic Island", isOn: $lyricsInDynamicIsland)
                        .onChange(of: lyricsInDynamicIsland) { _, _ in
                            PlayerEngine.shared.publishExternalState()
                        }
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text("Shows the current lyric line next to the camera. iOS keeps its own Now Playing bubble too, so you'll see two bubbles while this is on.")
                }

                Section {
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                    LabeledContent("Albums", value: "\(library.albums.count)")
                    LabeledContent("Artists", value: "\(library.artists.count)")
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        HStack {
                            Text("Rescan Library")
                            if library.isScanning { Spacer(); ProgressView() }
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Copied songs live in Files › On My iPhone › MHM. Subfolders are fine.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Widget storage", value: AppGroup.containerURL == nil ? "Unavailable" : "OK")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .addMusicImporter($importMode)
        }
    }
}
