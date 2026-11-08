import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage("autoArtwork") private var autoArtwork = true
    @AppStorage("autoLyrics") private var autoLyrics = true
    @AppStorage("lyricsInDynamicIsland") private var lyricsInDynamicIsland = false
    @State private var importMode: ImportMode?

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(library.linkedFolders) { folder in
                        HStack {
                            Image(systemName: library.isFolderAvailable(folder) ? "folder.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(library.isFolderAvailable(folder) ? Color.accentColor : .orange)
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
