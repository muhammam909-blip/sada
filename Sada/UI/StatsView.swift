import Charts
import SwiftUI

struct StatsView: View {
    enum Range: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "This Year", all = "All Time"
        var id: String { rawValue }
        var start: Date {
            let now = Date()
            switch self {
            case .week: return now.addingTimeInterval(-7 * 86400)
            case .month: return now.addingTimeInterval(-30 * 86400)
            case .year: return Calendar.current.date(from: Calendar.current.dateComponents([.year], from: now)) ?? now
            case .all: return .distantPast
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var range: Range = .month

    var body: some View {
        let events = library.plays.filter { $0.date >= range.start }
        let minutes = Int(events.reduce(0) { $0 + $1.seconds } / 60)
        let songCounts = Dictionary(grouping: events, by: \.id).mapValues(\.count)
        let topSongs = songCounts.sorted { $0.value > $1.value }.prefix(10).compactMap { pair in
            library.track(id: pair.key).map { ($0, pair.value) }
        }
        let topArtists = artistTotals(events).prefix(5)
        let daily = dailyMinutes(events)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if range == .year, let top = topSongs.first {
                    WrappedCard(year: Calendar.current.component(.year, from: Date()), minutes: minutes,
                                topSong: top.0, topArtist: topArtists.first?.key, songsPlayed: songCounts.count)
                }

                HStack(spacing: 12) {
                    StatTile(value: "\(minutes)", label: "minutes")
                    StatTile(value: "\(events.count)", label: "plays")
                    StatTile(value: "\(songCounts.count)", label: "songs")
                }

                if !daily.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Listening Time").font(.headline)
                        Chart(daily, id: \.0) { item in
                            BarMark(x: .value("Day", item.0, unit: .day), y: .value("Minutes", item.1))
                                .foregroundStyle(.tint)
                                .cornerRadius(3)
                        }
                        .frame(height: 160)
                    }
                }

                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top Songs").font(.headline)
                        ForEach(Array(topSongs.enumerated()), id: \.offset) { i, pair in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                                TrackRow(track: pair.0)
                                Text("\(pair.1)×").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .onTapGesture { player.play(topSongs.map(\.0), startAt: i) }
                        }
                    }
                }

                if !topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top Artists").font(.headline)
                        ForEach(Array(topArtists.enumerated()), id: \.offset) { i, pair in
                            HStack {
                                Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                                Text(pair.key)
                                Spacer()
                                Text("\(Int(pair.value / 60)) min").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if events.isEmpty {
                    ContentUnavailableView("No listening yet", systemImage: "chart.bar",
                                           description: Text("Songs count after 30 seconds of listening."))
                }
            }
            .padding()
        }
        .navigationTitle("Your Stats")
    }

    private func artistTotals(_ events: [PlayEvent]) -> [(key: String, value: Double)] {
        var totals: [String: Double] = [:]
        for e in events {
            if let t = library.track(id: e.id) { totals[t.albumArtistName, default: 0] += e.seconds }
        }
        return totals.sorted { $0.value > $1.value }.map { (key: $0.key, value: $0.value) }
    }

    private func dailyMinutes(_ events: [PlayEvent]) -> [(Date, Double)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: events) { cal.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds } / 60) }
            .sorted { $0.0 < $1.0 }
            .suffix(60)
            .map { $0 }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title.bold().monospacedDigit()).foregroundStyle(.tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Year summary card ("Wrapped").
struct WrappedCard: View {
    let year: Int
    let minutes: Int
    let topSong: Track
    let topArtist: String?
    let songsPlayed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your \(String(year)) on MHM").font(.title2.bold())
            HStack(spacing: 14) {
                ArtworkView(track: topSong, cornerRadius: 10, pixelSize: 300)
                    .frame(width: 92, height: 92)
                    .shadow(radius: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOP SONG").font(.caption2.weight(.bold)).opacity(0.7)
                    Text(topSong.title).font(.headline).lineLimit(2)
                    Text(topSong.displayArtist).font(.subheadline).opacity(0.8)
                }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("\(minutes)").font(.title.bold().monospacedDigit())
                    Text("minutes listened").font(.caption).opacity(0.8)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(topArtist ?? "—").font(.headline).lineLimit(1)
                    Text("top artist · \(songsPlayed) songs").font(.caption).opacity(0.8)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            LinearGradient(colors: [Color(red: 1, green: 0.25, blue: 0.45), Color(red: 0.45, green: 0.2, blue: 0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}
