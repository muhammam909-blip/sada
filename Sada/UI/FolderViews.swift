import SwiftUI

/// Top level of the folder view: the app's own folder plus every linked folder.
struct FolderRootsList: View {
    @Environment(LibraryStore.self) private var library
    @Binding var importMode: ImportMode?

    var body: some View {
        VStack(spacing: 0) {
            FolderRootRow(name: "On My iPhone", subtitle: "MHM", icon: "iphone",
                          count: library.tracks.filter { $0.sourceID == nil }.count,
                          route: .folder(source: nil, path: "", title: "On My iPhone"))
            ForEach(library.linkedFolders) { folder in
                Divider().padding(.leading, 56)
                FolderRootRow(name: folder.name, subtitle: library.isFolderAvailable(folder) ? "Linked folder" : "Unavailable",
                              icon: "link", count: library.tracks.filter { $0.sourceID == folder.id }.count,
                              route: .folder(source: folder.id, path: "", title: folder.name))
            }
            Divider().padding(.leading, 56)
            Button { importMode = .linkFolder } label: {
                HStack(spacing: 16) {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint).frame(width: 40)
                    Text("Link Another Folder").foregroundStyle(.tint)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
}

struct FolderRootRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let count: Int
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: icon).font(.caption2.bold()).foregroundStyle(.white).offset(x: -4, y: -3)
                    }
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One folder: its subfolders and songs, with move / delete / rename / new folder.
struct FolderBrowserView: View {
    let sourceID: String?
    let path: String
    let title: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var askNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameText = ""
    @State private var deletingFolder: String?
    @State private var confirmDeleteSelected = false
    @AppStorage("folderShowFileNames") private var showFileNames = false

    private func childPath(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }

    var body: some View {
        let _ = library.folderRevision
        let listing = library.listing(sourceID: sourceID, path: path)
        let all = library.tracksRecursive(sourceID: sourceID, path: path)

        List(selection: $selection) {
            if !all.isEmpty && !editMode.isEditing {
                PlayShuffleButtons(tracks: all)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }

            if !listing.folders.isEmpty {
                Section {
                    ForEach(listing.folders, id: \.self) { name in
                        let sub = childPath(name)
                        NavigationLink(value: Route.folder(source: sourceID, path: sub, title: name)) {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint).frame(width: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name).lineLimit(1)
                                    Text("\(library.tracksRecursive(sourceID: sourceID, path: sub).count) songs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .selectionDisabled()
                        .contextMenu {
                            let songs = library.tracksRecursive(sourceID: sourceID, path: sub)
                            Button { player.play(songs, startAt: 0, shuffle: false) } label: { Label("Play", systemImage: "play") }
                            Button { player.shuffleAll(songs) } label: { Label("Shuffle", systemImage: "shuffle") }
                            Divider()
                            Button { renameText = name; renamingFolder = sub } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deletingFolder = sub } label: { Label("Delete Folder", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { deletingFolder = sub } label: { Label("Delete", systemImage: "trash") }
                            Button { renameText = name; renamingFolder = sub } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.orange)
                        }
                    }
                }
            }

            if !listing.tracks.isEmpty {
                Section {
                    ForEach(Array(listing.tracks.enumerated()), id: \.element.id) { i, track in
                        FileTrackRow(track: track, showFileName: showFileNames)
                            .tag(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !editMode.isEditing { player.play(listing.tracks, startAt: i) }
                            }
                            .contextMenu { TrackMenuItems(track: track) }
                            .swipeActions {
                                Button(role: .destructive) { router.deleteCandidate = track } label: { Label("Delete", systemImage: "trash") }
                                Button { router.trackSheet = .move([track.id]) } label: { Label("Move", systemImage: "folder") }
                                    .tint(.indigo)
                            }
                    }
                }
            }

            if listing.folders.isEmpty && listing.tracks.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Move songs here from another folder, or add music with +."))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("Done") { withAnimation { editMode = .inactive; selection.removeAll() } }
                } else {
                    Menu {
                        Button { withAnimation { editMode = .active } } label: { Label("Select Songs", systemImage: "checkmark.circle") }
                        Button { newFolderName = ""; askNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Toggle(isOn: $showFileNames) { Label("Show File Names", systemImage: "doc.text") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Select All") { selection = Set(listing.tracks.map(\.id)) }
                    Spacer()
                    Button { router.trackSheet = .move(Array(selection)) } label: { Label("Move", systemImage: "folder") }
                        .disabled(selection.isEmpty)
                    Button(role: .destructive) { confirmDeleteSelected = true } label: { Label("Delete", systemImage: "trash") }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .alert("New Folder", isPresented: $askNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { library.createFolder(sourceID: sourceID, parent: path, name: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let p = renamingFolder { library.renameFolder(sourceID: sourceID, path: p, to: renameText) }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .confirmationDialog(
            "Delete this folder and the \(deletingFolder.map { library.tracksRecursive(sourceID: sourceID, path: $0).count } ?? 0) songs inside?",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let p = deletingFolder { library.deleteFolder(sourceID: sourceID, path: p) }
                deletingFolder = nil
            }
        } message: {
            Text("The files are removed from your iPhone. This can't be undone.")
        }
        .confirmationDialog("Delete \(selection.count) songs?", isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for id in selection { if let t = library.track(id: id) { library.delete(t) } }
                selection.removeAll()
                editMode = .inactive
            }
        } message: {
            Text("The files are removed from your iPhone. This can't be undone.")
        }
        .onChange(of: router.trackSheet == nil) { _, closed in
            // After a move finishes, leave selection mode.
            if closed && editMode.isEditing { selection.removeAll(); editMode = .inactive }
        }
    }
}

struct FileTrackRow: View {
    let track: Track
    var showFileName = false
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 12) {
            ArtworkView(track: track, cornerRadius: 6, pixelSize: 132)
                .frame(width: 44, height: 44)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                        NowPlayingBars(animating: player.isPlaying).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(showFileName ? (track.relativePath as NSString).lastPathComponent : track.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text("\(track.displayArtist) · \(formatTime(track.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MoveToFolderSheet: View {
    let trackIDs: [String]
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(sourceID: String?, path: String, name: String)] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    Button {
                        library.move(trackIDs, toSource: folder.sourceID, folder: folder.path)
                        dismiss()
                    } label: {
                        Label(folder.name, systemImage: folder.path.isEmpty ? "internaldrive" : "folder")
                            .padding(.leading, CGFloat(folder.path.split(separator: "/").count) * 14)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(trackIDs.count == 1 ? "Move Song" : "Move \(trackIDs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { folders = library.allFolders() }
        }
    }
}

/// Multi-select song picker used to add songs to a playlist or to Favorites.
struct AddSongsSheet: View {
    let playlistID: String?
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            let key = filter.searchKey
            let list = key.isEmpty ? library.tracks : library.tracks.filter {
                $0.title.searchKey.contains(key) || $0.displayArtist.searchKey.contains(key) || $0.displayAlbum.searchKey.contains(key)
            }
            List(list) { track in
                Button {
                    if let i = picked.firstIndex(of: track.id) { picked.remove(at: i) } else { picked.append(track.id) }
                } label: {
                    HStack {
                        TrackRow(track: track)
                        Image(systemName: picked.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked.contains(track.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find songs")
            .navigationTitle(playlistID == nil ? "Add to Favorites" : "Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        if let playlistID { library.add(picked, to: playlistID) } else { library.addFavorites(picked) }
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}
