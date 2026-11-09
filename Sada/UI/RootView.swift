import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @AppStorage(ThemeKeys.accent) private var accentHex = AccentPreset.pink.rawValue
    @AppStorage(TabSettings.orderKey) private var tabOrder = TabSettings.defaultOrder
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true
    @AppStorage(TabSettings.videosTabKey) private var videosSeparate = false
    @AppStorage("tabs.nameRevision") private var nameRevision = 0

    private var tabs: [AppTab] { TabSettings.visible(order: tabOrder, online: onlineEnabled, videosSeparate: videosSeparate) }

    @ViewBuilder private func content(for tab: AppTab) -> some View {
        switch tab {
        case .online: OnlineView()
        case .folders: FoldersTab()
        case .videos: NavigationStack { VideosView().libraryDestinations() }
        case .library: LibraryView()
        case .search: SearchView()
        }
    }
    @Namespace private var namespace

    /// Classic design: the mini player floats just above the tab bar on every tab.
    @ViewBuilder private var miniPlayer: some View {
        if player.current != nil {
            MiniPlayerView { router.showNowPlaying = true }
                .frame(height: 58)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .matchedTransitionSource(id: "nowPlaying", in: namespace)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        @Bindable var router = router
        let _ = nameRevision
        TabView(selection: $router.tab) {
            ForEach(tabs) { tab in
                Tab(TabSettings.name(tab), systemImage: tab.icon, value: tab) {
                    content(for: tab).safeAreaInset(edge: .bottom) { miniPlayer }
                }
            }
            Tab(TabSettings.name(.search), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView().safeAreaInset(edge: .bottom) { miniPlayer }
            }
        }
        .onAppear { if !tabs.contains(router.tab) { router.tab = tabs.first ?? .folders } }
        .onChange(of: tabs) { _, new in if !new.contains(router.tab) && router.tab != .search { router.tab = new.first ?? .folders } }
        .fullScreenCover(item: $router.playingVideo) { video in
            VideoPlayerScreen(item: video)
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
    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.current, cornerRadius: 6, pixelSize: 120)
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    if player.current?.isOnline == true {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(.tint, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
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
        .offset(x: dragX)
        .opacity(1 - min(abs(dragX) / 250, 0.6))
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { onOpen() } }
        // Swipe left = next, right = previous, up = open the player.
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { g in
                    if abs(g.translation.width) > abs(g.translation.height) { dragX = g.translation.width * 0.6 }
                }
                .onEnded { g in
                    if g.translation.height < -30, abs(g.translation.height) > abs(g.translation.width) {
                        if player.current != nil { onOpen() }
                    } else if g.translation.width < -70 {
                        player.next()
                    } else if g.translation.width > 70 {
                        player.previous()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragX = 0 }
                }
        )
        .sensoryFeedback(.selection, trigger: player.current?.id)
        .animation(.smooth, value: player.current?.id)
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
                case .moveItems(let t, let f, let s): MoveToFolderSheet(trackIDs: t, folderPaths: f, folderSource: s)
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
