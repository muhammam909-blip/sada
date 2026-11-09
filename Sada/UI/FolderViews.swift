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

/// One folder: its subfolders and songs. Select songs *and* folders to move or delete them.
struct FolderBrowserView: View {
    let sourceID: String?
    let path: String
    let title: String
    var isRoot = false

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
    @State private var importMode: ImportMode?

    private static let folderTag = "folder:"
    private func childPath(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
    private var selectedFolders: [String] {
        selection.filter { $0.hasPrefix(Self.folderTag) }.map { String($0.dropFirst(Self.folderTag.count)) }
    }
    private var selectedTracks: [String] { selection.filter { !$0.hasPrefix(Self.folderTag) } }

    var body: some View {
        let _ = library.folderRevision
        let listing = library.listing(sourceID: sourceID, path: path)
        let all = library.tracksRecursive(sourceID: sourceID, path: path)

        List(selection: $selection) {
            if !all.isEmpty && !editMode.isEditing {
                PlayShuffleButtons(tracks: all)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                ImportStatusBanner()
                    .listRowSeparator(.hidden)
            }

            if !listing.folders.isEmpty {
                Section {
                    ForEach(listing.folders, id: \.self) { name in
                        let sub = childPath(name)
                        NavigationLink(value: Route.folder(source: sourceID, path: sub, title: name)) {
                            FolderRow(name: name, count: library.tracksRecursive(sourceID: sourceID, path: sub).count)
                        }
                        .tag(Self.folderTag + sub)
                        .contextMenu {
                            let songs = library.tracksRecursive(sourceID: sourceID, path: sub)
                            Button { player.play(songs, startAt: 0, shuffle: false) } label: { Label("Play", systemImage: "play") }
                            Button { player.shuffleAll(songs) } label: { Label("Shuffle", systemImage: "shuffle") }
                            Divider()
                            Button { router.trackSheet = .moveItems(tracks: [], folders: [sub], source: sourceID) } label: { Label("Move to…", systemImage: "folder") }
                            Button { renameText = name; renamingFolder = sub } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deletingFolder = sub } label: { Label("Delete Folder", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { deletingFolder = sub } label: { Label("Delete", systemImage: "trash") }
                            Button { router.trackSheet = .moveItems(tracks: [], folders: [sub], source: sourceID) } label: { Label("Move", systemImage: "folder") }
                                .tint(.indigo)
                        }
                    }
                }
            }

            if !listing.tracks.isEmpty {
                Section {
                    ForEach(Array(listing.tracks.enumerated()), id: \.element.id) { i, track in
                        FileTrackRow(track: track)
                            .tag(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !editMode.isEditing { player.play(listing.tracks, startAt: i) }
                            }
                            .trackContextMenu(track)
                            .swipeActions {
                                Button(role: .destructive) { router.deleteCandidate = track } label: { Label("Delete", systemImage: "trash") }
                                Button { router.trackSheet = .move([track.id]) } label: { Label("Move", systemImage: "folder") }
                                    .tint(.indigo)
                            }
                            .swipeActions(edge: .leading) {
                                Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                    .tint(.orange)
                            }
                    }
                }
            }

            if isRoot && !library.linkedFolders.isEmpty && !editMode.isEditing {
                Section("Linked Folders") {
                    ForEach(library.linkedFolders) { folder in
                        NavigationLink(value: Route.folder(source: folder.id, path: "", title: folder.name)) {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill.badge.gearshape")
                                    .font(.title2).foregroundStyle(.tint).frame(width: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.name).lineLimit(1)
                                    Text(library.isFolderAvailable(folder)
                                         ? "\(library.tracks.filter { $0.sourceID == folder.id }.count) songs · linked"
                                         : "Unavailable")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .selectionDisabled()
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
        .animation(.snappy, value: listing.folders)
        .animation(.snappy, value: listing.tracks.map(\.id))
        .modifier(FolderTitle(title: title, isRoot: isRoot))
        .refreshable { await library.rescan() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("Done") { withAnimation { editMode = .inactive; selection.removeAll() } }
                        .fontWeight(.semibold)
                } else {
                    Menu {
                        Button { withAnimation { editMode = .active } } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { newFolderName = ""; askNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        // While selecting: hide the tab bar and show a floating action bar in its place.
        .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack(spacing: 10) {
                    Button(selection.isEmpty ? "Select All" : "Deselect") {
                        if selection.isEmpty {
                            selection = Set(listing.tracks.map(\.id) + listing.folders.map { Self.folderTag + childPath($0) })
                        } else {
                            selection.removeAll()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(selection.isEmpty ? "None selected" : "\(selection.count) selected")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        router.trackSheet = .moveItems(tracks: selectedTracks, folders: selectedFolders, source: sourceID)
                    } label: {
                        Image(systemName: "folder").font(.title3).frame(width: 44, height: 44)
                    }
                    .disabled(selection.isEmpty)
                    Button(role: .destructive) { confirmDeleteSelected = true } label: {
                        Image(systemName: "trash").font(.title3).frame(width: 44, height: 44)
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: editMode.isEditing)
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
        .confirmationDialog("Delete \(selection.count) selected items?", isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for id in selectedTracks { if let t = library.track(id: id) { library.delete(t) } }
                for folder in selectedFolders { library.deleteFolder(sourceID: sourceID, path: folder) }
                selection.removeAll()
                editMode = .inactive
            }
        } message: {
            Text("Selected songs and folders (with everything inside) are removed from your iPhone. This can't be undone.")
        }
        .onChange(of: router.trackSheet == nil) { _, closed in
            if closed && editMode.isEditing { selection.removeAll(); editMode = .inactive }
        }
    }
}

struct FolderRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(count == 1 ? "1 song" : "\(count) songs").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FileTrackRow: View {
    let track: Track
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
                Text(track.title)
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
    var folderPaths: [String] = []
    var folderSource: String? = nil
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(sourceID: String?, path: String, name: String)] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    Button {
                        if !trackIDs.isEmpty { library.move(trackIDs, toSource: folder.sourceID, folder: folder.path) }
                        for path in folderPaths {
                            library.moveFolder(sourceID: folderSource, path: path, toSource: folder.sourceID, folder: folder.path)
                        }
                        dismiss()
                    } label: {
                        Label(folder.name, systemImage: folder.path.isEmpty ? "internaldrive" : "folder")
                            .padding(.leading, CGFloat(folder.path.split(separator: "/").count) * 14)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Move \(trackIDs.count + folderPaths.count) Item\(trackIDs.count + folderPaths.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                // Hide the folders being moved (and their subfolders) as destinations.
                folders = library.allFolders().filter { f in
                    !(f.sourceID == folderSource && folderPaths.contains { f.path == $0 || f.path.hasPrefix($0 + "/") })
                }
            }
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

/// The root folder screen shows the MHM logo header; subfolders show their own name.
struct FolderTitle: ViewModifier {
    let title: String
    let isRoot: Bool

    func body(content: Content) -> some View {
        if isRoot {
            content.brandHeader(TabSettings.name(.folders))
        } else {
            content.navigationTitle(title)
        }
    }
}
