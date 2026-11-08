import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @Namespace private var namespace

    var body: some View {
        @Bindable var router = router
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }
            Tab("Library", systemImage: "square.stack.fill") {
                LibraryView()
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerView { router.showNowPlaying = true }
                .matchedTransitionSource(id: "nowPlaying", in: namespace)
        }
        .fullScreenCover(isPresented: $router.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "nowPlaying", in: namespace))
        }
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
