import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage(ThemeKeys.accent) private var accentHex = AccentPreset.pink.rawValue
    @Namespace private var namespace

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Online", systemImage: "globe", value: AppTab.online) {
                OnlineView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerView { router.showNowPlaying = true }
                .matchedTransitionSource(id: "nowPlaying", in: namespace)
        }
        .trackActionSheets(enabled: !router.showNowPlaying)
        .fullScreenCover(isPresented: $router.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "nowPlaying", in: namespace))
                .trackActionSheets(enabled: true)
        }
        .preferredColorScheme(appearance.scheme)
        .tint(Color(hex: accentHex))
    }
}

struct MiniPlayerView: View {
    var onOpen: () -> Void

    @Environment(PlayerEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.current, cornerRadius: 6, pixelSize: 120)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if placement != .inline, let artist = player.current?.displayArtist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
            }
            if placement != .inline {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { onOpen() } }
    }
}

// MARK: - Sheets & dialogs triggered from any song menu

struct TrackActionSheets: ViewModifier {
    let enabled: Bool
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        let sheet = Binding<TrackSheet?>(
            get: { enabled ? router.trackSheet : nil },
            set: { router.trackSheet = $0 }
        )
        let deleting = Binding<Bool>(
            get: { enabled && router.deleteCandidate != nil },
            set: { if !$0 { router.deleteCandidate = nil } }
        )
        let candidate = router.deleteCandidate
        content
            .sheet(item: sheet) { item in
                switch item {
                case .edit(let t): TrackInfoEditor(track: t)
                case .artwork(let t): ArtworkSearchSheet(track: t)
                case .lyrics(let t): LyricsSearchSheet(track: t)
                case .addToPlaylist(let t): PlaylistPickerSheet(track: t)
                case .move(let ids): MoveToFolderSheet(trackIDs: ids)
                case .addSongs(let p): AddSongsSheet(playlistID: p)
                }
            }
            .confirmationDialog(
                "Delete “\(candidate?.title ?? "")”?",
                isPresented: deleting,
                titleVisibility: .visible
            ) {
                Button("Delete Song", role: .destructive) {
                    if let candidate { library.delete(candidate) }
                    router.deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) { router.deleteCandidate = nil }
            } message: {
                Text(candidate?.sourceID == nil
                     ? "The file will be removed from your iPhone. This can't be undone."
                     : "This song is in a linked folder. The file will be deleted from that folder too. This can't be undone.")
            }
    }
}

extension View {
    func trackActionSheets(enabled: Bool) -> some View {
        modifier(TrackActionSheets(enabled: enabled))
    }
}
