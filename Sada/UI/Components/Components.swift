import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Artwork

struct ArtworkView: View {
    let track: Track?
    var cornerRadius: CGFloat = 8
    var pixelSize: CGFloat = 200

    @Environment(LibraryStore.self) private var library
    @State private var image: UIImage?

    private var taskKey: String {
        "\(track?.id ?? "-")|\(track?.hasArtwork ?? false)|\(library.artworkRevision)"
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder(seed: track?.albumID ?? "sada")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .task(id: taskKey) {
                guard let track, track.hasArtwork else { image = nil; return }
                let loaded = await ArtworkCache.shared.image(for: track.id, pixelSize: pixelSize)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

struct ArtworkPlaceholder: View {
    let seed: String

    private var colors: [Color] {
        let palettes: [[Color]] = [
            [.pink, .purple], [.orange, .red], [.teal, .blue], [.indigo, .purple],
            [.mint, .teal], [.red, .pink], [.blue, .cyan], [.purple, .indigo],
        ]
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palettes[hash % palettes.count]
    }

    var body: some View {
        LinearGradient(colors: colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                GeometryReader { geo in
                    Image(systemName: "music.note")
                        .font(.system(size: geo.size.width * 0.36, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

// MARK: - Rows & cards

struct TrackRow: View {
    let track: Track
    var showArtwork = true
    var number: Int?

    @Environment(PlayerEngine.self) private var player

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        NowPlayingBars(animating: player.isPlaying)
                    } else {
                        Text("\(number)").foregroundStyle(.secondary)
                    }
                }
                .font(.body.monospacedDigit())
                .frame(width: 26)
            } else if showArtwork {
                ArtworkView(track: track, cornerRadius: 6, pixelSize: 132)
                    .frame(width: 46, height: 46)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                            NowPlayingBars(animating: player.isPlaying).foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if number != nil {
                Text(formatTime(track.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct NowPlayingBars: View {
    let animating: Bool
    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: animating)
            .foregroundStyle(Color.accentColor)
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.artworkTrack, cornerRadius: 10, pixelSize: 480)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

/// Context-menu actions shared by every song list.
struct TrackMenuItems: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(track) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button {
            Task { await MetadataEnricher.shared.refetchArtwork(for: track) }
        } label: { Label("Find Artwork", systemImage: "photo.badge.magnifyingglass") }
        Button {
            Task { _ = await MetadataEnricher.shared.fetchLyrics(for: track, force: true) }
        } label: { Label("Find Lyrics", systemImage: "quote.bubble") }
    }
}

struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.play(tracks, startAt: 0, shuffle: false)
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                player.shuffleAll(tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .font(.headline)
        .buttonStyle(.glass)
        .controlSize(.large)
        .tint(.accentColor)
        .disabled(tracks.isEmpty)
    }
}

// MARK: - UIKit wrappers

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = .systemPink
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Navigation

extension View {
    func libraryDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumDetailView(albumID: id)
            case .artist(let id): ArtistDetailView(artistID: id)
            case .songs: SongsView()
            case .albums: AlbumsGridView()
            case .artists: ArtistsListView()
            }
        }
    }
}
