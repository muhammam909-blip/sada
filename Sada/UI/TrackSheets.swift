import PhotosUI
import SwiftUI

// MARK: - Edit info

struct TrackInfoEditor: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                } footer: {
                    Text("Correct names help find artwork and lyrics. Tip: write Arabic songs in Arabic letters (e.g. عبد الحليم حافظ) instead of Franco.")
                }
                Section {
                    LabeledContent("File", value: track.relativePath)
                        .font(.footnote)
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.updateInfo(track.id, title: title, artist: artist, album: album)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = track.title
                artist = track.artist
                album = track.album
            }
        }
    }
}

// MARK: - Artwork picker

struct ArtworkSearchSheet: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ArtworkCandidate] = []
    @State private var loading = false
    @State private var applying: String?
    @State private var photo: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("Artist and album or song", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }
                            .buttonStyle(.glass)
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    } else if results.isEmpty {
                        Text("No results yet. Try the artist name plus the album, in Arabic or English.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(results) { item in
                            Button {
                                Task { await apply(item) }
                            } label: {
                                AsyncImage(url: item.thumbURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.15)
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    if applying == item.id {
                                        RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4))
                                        ProgressView().tint(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.caption)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Find Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                query = [track.hasKnownArtist ? track.artist : nil, track.hasKnownAlbum ? track.album : track.title]
                    .compactMap { $0 }.joined(separator: " ")
                await search()
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await library.setArtwork(data, for: track.id, applyToAlbum: true)
                        dismiss()
                    }
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        results = await ArtworkFetcher.candidates(query: q)
        loading = false
    }

    private func apply(_ item: ArtworkCandidate) async {
        applying = item.id
        if case let (data, 200)? = await HTTP.get(item.fullURL) {
            await library.setArtwork(data, for: track.id, applyToAlbum: true)
            dismiss()
        }
        applying = nil
    }
}

// MARK: - Lyrics picker

struct LyricsSearchSheet: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var results: [LyricsCandidate] = []
    @State private var loading = false
    @State private var searched = false
    @State private var pasted = ""
    @State private var showPaste = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song title", text: $title)
                    TextField("Artist", text: $artist)
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Search", systemImage: "magnifyingglass")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                } footer: {
                    Text("Searches LRCLIB. If the title is in Franco (7abibi), try Arabic letters.")
                }

                if searched && results.isEmpty && !loading {
                    Section { Text("Nothing found. Try another spelling, or paste the lyrics yourself.").foregroundStyle(.secondary) }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { item in
                            NavigationLink {
                                LyricsPreview(candidate: item) {
                                    if let text = item.text { library.setLyrics(text, for: track.id) }
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                                        if item.synced != nil {
                                            Text("SYNCED")
                                                .font(.caption2.weight(.bold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    Text([item.artist, item.album, item.duration.map { formatTime($0) }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button { showPaste = true } label: { Label("Paste Lyrics Manually", systemImage: "doc.on.clipboard") }
                }
            }
            .navigationTitle("Find Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                title = TitleCleaner.clean(track.title)
                artist = track.hasKnownArtist ? track.artist : ""
                await search()
            }
            .sheet(isPresented: $showPaste) {
                NavigationStack {
                    TextEditor(text: $pasted)
                        .padding()
                        .navigationTitle("Paste Lyrics")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPaste = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") {
                                    library.setLyrics(pasted, for: track.id)
                                    showPaste = false
                                    dismiss()
                                }
                                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
            }
        }
    }

    private func search() async {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true
        results = await LyricsFetcher.search(title: title, artist: artist)
        loading = false
        searched = true
    }
}

struct LyricsPreview: View {
    let candidate: LyricsCandidate
    var onUse: () -> Void

    var body: some View {
        let doc = LRCParser.parse(candidate.text ?? "")
        ScrollView {
            VStack(alignment: doc.isRTL ? .trailing : .leading, spacing: 10) {
                ForEach(doc.lines) { line in
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(doc.isRTL ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: doc.isRTL ? .trailing : .leading)
            .padding()
        }
        .navigationTitle(candidate.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Use These", action: onUse) }
        }
    }
}

// MARK: - Add to playlist

struct PlaylistPickerSheet: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askName = false

    var body: some View {
        NavigationStack {
            List {
                Button { askName = true } label: { Label("New Playlist…", systemImage: "plus") }
                ForEach(library.playlists) { playlist in
                    Button {
                        library.add(track.id, to: playlist.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(playlist: playlist).frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(playlist.name).foregroundStyle(.primary)
                                Text("\(playlist.trackIDs.count) songs").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Playlist", isPresented: $askName) {
                TextField("Name", text: $newName)
                Button("Create") {
                    library.createPlaylist(named: newName, with: [track.id])
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
