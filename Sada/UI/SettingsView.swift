import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoArtwork") private var autoArtwork = true
    @AppStorage("autoLyrics") private var autoLyrics = true
    @AppStorage("lyricsInDynamicIsland") private var lyricsInDynamicIsland = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Find Missing Artwork", isOn: $autoArtwork)
                    Toggle("Find Missing Lyrics", isOn: $autoLyrics)
                    Button("Search Now") { MetadataEnricher.shared.start() }
                    if let status = library.enrichmentStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Automatic Metadata")
                } footer: {
                    Text("Artwork comes from Deezer and Apple Music, lyrics from LRCLIB (synced when available). Works for Arabic and English songs.")
                }

                Section {
                    Toggle("Live Lyrics in Dynamic Island", isOn: $lyricsInDynamicIsland)
                        .onChange(of: lyricsInDynamicIsland) { _, _ in
                            PlayerEngine.shared.publishExternalState()
                        }
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text("The regular Now Playing island and Lock Screen controls are always on. This adds a second island that shows the current lyric line.")
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
                    Text("Put music in Files › On My iPhone › Sada. Subfolders are fine.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
