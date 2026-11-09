import SwiftUI
import UniformTypeIdentifiers

enum ImportMode {
    case linkFolder, copyFolder, copyFiles

    var types: [UTType] {
        switch self {
        case .linkFolder, .copyFolder: [.folder]
        case .copyFiles: [.audio, .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, UTType(filenameExtension: "mkv") ?? .movie, UTType(filenameExtension: "srt") ?? .plainText]
        }
    }
}

/// "+" menu: link a folder (no copy), copy a whole folder, or pick files.
struct AddMusicMenu: View {
    @Binding var mode: ImportMode?

    var body: some View {
        Menu {
            Button { mode = .linkFolder } label: {
                Label("Link a Folder (no copy)", systemImage: "link")
            }
            Button { mode = .copyFolder } label: {
                Label("Copy a Whole Folder", systemImage: "folder.badge.plus")
            }
            Button { mode = .copyFiles } label: {
                Label("Choose Songs or Videos", systemImage: "music.note.list")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

struct AddMusicImporter: ViewModifier {
    @Binding var mode: ImportMode?
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        let presented = Binding<Bool>(get: { mode != nil }, set: { if !$0 { mode = nil } })
        let current = mode ?? .copyFiles
        content.fileImporter(
            isPresented: presented,
            allowedContentTypes: current.types,
            allowsMultipleSelection: current != .linkFolder
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                switch current {
                case .linkFolder:
                    for url in urls { await library.linkFolder(url) }
                case .copyFolder, .copyFiles:
                    await library.importFiles(urls)
                }
            }
        }
    }
}

extension View {
    func addMusicImporter(_ mode: Binding<ImportMode?>) -> some View {
        modifier(AddMusicImporter(mode: mode))
    }
}

struct ImportStatusBanner: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let status = library.importStatus ?? library.enrichmentStatus {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }
}
