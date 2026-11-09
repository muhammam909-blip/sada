import AVFoundation
import SwiftUI

struct SubtitleSheet: View {
    let controller: VideoPlayerController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("subtitle.size") private var subtitleSize: Double = 20
    @State private var showOnline = false

    var body: some View {
        NavigationStack {
            List {
                Section("Subtitles") {
                    row("Off", selected: controller.activeSubtitleName == nil) { controller.subtitlesOff() }
                    ForEach(controller.legibleOptions, id: \.self) { option in
                        row(option.displayName + " (built-in)", selected: controller.selectedLegible == option) {
                            controller.selectLegible(option)
                        }
                    }
                    ForEach(VideoStore.shared.subtitleFiles(for: controller.item), id: \.self) { url in
                        row(url.deletingPathExtension().lastPathComponent,
                            selected: controller.activeSubtitleName == url.deletingPathExtension().lastPathComponent) {
                            controller.loadExternal(url)
                        }
                    }
                    Button { showOnline = true } label: {
                        Label("Search Online…", systemImage: "magnifyingglass")
                    }
                }

                Section {
                    Stepper(value: Binding(get: { controller.subtitleDelay }, set: { controller.subtitleDelay = $0 }), in: -30...30, step: 0.5) {
                        LabeledContent("Delay", value: String(format: "%+.1f s", controller.subtitleDelay))
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Text Size", value: "\(Int(subtitleSize))")
                        Slider(value: $subtitleSize, in: 14...36, step: 1)
                    }
                } header: {
                    Text("Timing & Size")
                } footer: {
                    Text("Use Delay if the subtitles show too early (+) or too late (−).")
                }

                if controller.audibleOptions.count > 1 {
                    Section("Audio Track") {
                        ForEach(controller.audibleOptions, id: \.self) { option in
                            row(option.displayName, selected: controller.selectedAudible == option) {
                                controller.selectAudible(option)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Subtitles & Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showOnline) {
                OnlineSubtitleSearch(controller: controller) { dismiss() }
            }
        }
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

struct OnlineSubtitleSearch: View {
    let controller: VideoPlayerController
    var onDone: () -> Void
    @AppStorage("subtitle.language") private var language = "ar"
    @State private var query = ""
    @State private var results: [OpenSubtitles.Result] = []
    @State private var loading = false
    @State private var error: String?
    @State private var downloading: Int?

    var body: some View {
        List {
            Section {
                TextField("Title", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                Picker("Language", selection: $language) {
                    Text("Arabic").tag("ar")
                    Text("English").tag("en")
                    Text("Both").tag("ar,en")
                }
                .pickerStyle(.segmented)
                Button { Task { await search() } } label: {
                    HStack { Label("Search OpenSubtitles", systemImage: "magnifyingglass"); if loading { Spacer(); ProgressView() } }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(results) { r in
                Button { Task { await download(r) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.release).foregroundStyle(.primary).lineLimit(2).font(.subheadline)
                            Text("\(r.language.uppercased()) · \(r.downloads) downloads\(r.hearingImpaired ? " · HI" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloading == r.id { ProgressView() } else { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
                    }
                }
            }
        }
        .navigationTitle("Online Subtitles")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let v = controller.item
            query = v.kind == .episode ? (v.showName ?? v.title) : v.title
            await search()
        }
    }

    private func search() async {
        loading = true
        error = nil
        do {
            let v = controller.item
            results = try await OpenSubtitles.search(
                query: query, season: v.kind == .episode ? v.season : nil,
                episode: v.kind == .episode ? v.episode : nil, languages: language)
            if results.isEmpty { error = "No subtitles found. Try a different title." }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func download(_ r: OpenSubtitles.Result) async {
        downloading = r.id
        defer { downloading = nil }
        do {
            let text = try await OpenSubtitles.download(r)
            let url = VideoStore.shared.subtitlesDir.appendingPathComponent("\(controller.item.id).\(r.language).\(r.id).srt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            controller.loadExternal(url)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
