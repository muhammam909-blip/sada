import SwiftUI

/// Settings › Tabs: reorder, rename, turn Online on/off, Videos as its own tab.
struct TabSettingsView: View {
    @AppStorage(TabSettings.orderKey) private var orderRaw = TabSettings.defaultOrder
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true
    @AppStorage(TabSettings.videosTabKey) private var videosSeparate = false
    @AppStorage("tabs.nameRevision") private var nameRevision = 0
    @AppStorage(TabSettings.hiddenKey) private var hiddenRaw = ""
    @State private var names: [AppTab: String] = [:]

    /// One switch per tab. Online and Videos keep their own settings keys.
    private func shownBinding(_ tab: AppTab) -> Binding<Bool> {
        switch tab {
        case .online: return $onlineEnabled
        case .videos: return $videosSeparate
        default:
            return Binding(
                get: { !hiddenRaw.split(separator: ",").map(String.init).contains(tab.rawValue) },
                set: { show in
                    var set = Set(hiddenRaw.split(separator: ",").map(String.init))
                    if show { set.remove(tab.rawValue) } else { set.insert(tab.rawValue) }
                    hiddenRaw = set.sorted().joined(separator: ",")
                }
            )
        }
    }

    private var order: [AppTab] { TabSettings.order(orderRaw) }

    var body: some View {
        List {

            Section {
                ForEach(order) { tab in
                    HStack(spacing: 12) {
                        Image(systemName: tab.icon).foregroundStyle(.tint).frame(width: 26)
                        TextField(tab.defaultName, text: Binding(
                            get: { names[tab] ?? "" },
                            set: { value in
                                names[tab] = value
                                UserDefaults.standard.set(value, forKey: "tabs.name.\(tab.rawValue)")
                                nameRevision += 1
                            }
                        ))
                        Spacer()
                        Toggle("Show", isOn: shownBinding(tab)).labelsHidden()
                    }
                }
                .onMove { from, to in
                    var list = order
                    list.move(fromOffsets: from, toOffset: to)
                    orderRaw = list.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("Order & Names")
            } footer: {
                Text("Switch a tab off to hide it, on to bring it back. Drag to reorder and tap a name to rename it. Search always stays last.")
            }

            Section {
                Button("Reset to Default") {
                    orderRaw = TabSettings.defaultOrder
                    for tab in AppTab.allCases { UserDefaults.standard.removeObject(forKey: "tabs.name.\(tab.rawValue)") }
                    names = [:]
                    nameRevision += 1
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tabs")
        .onAppear {
            for tab in AppTab.allCases {
                names[tab] = UserDefaults.standard.string(forKey: "tabs.name.\(tab.rawValue)") ?? ""
            }
        }
    }
}

/// Settings › Videos & Player.
struct VideoSettingsView: View {
    @AppStorage("video.engine") private var engine = VideoEngineChoice.auto.rawValue
    @AppStorage("video.resume") private var resume = true
    @AppStorage("video.autoNext") private var autoNext = true
    @AppStorage("video.skip") private var skipSeconds = 10
    @AppStorage("video.gesture.brightness") private var brightnessGesture = true
    @AppStorage("video.gesture.volume") private var volumeGesture = true
    @AppStorage("video.gesture.seek") private var seekGesture = true
    @AppStorage("subtitle.language") private var language = "ar"
    @AppStorage("subtitle.size") private var subtitleSize: Double = 20
    @AppStorage("subtitle.background") private var subtitleBackground = true
    @AppStorage("subtitle.yellow") private var subtitleYellow = false
    @AppStorage("os.apiKey") private var apiKey = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                NavigationLink { AddonSettingsView() } label: {
                    LabeledContent("Online Sources", value: "\(AddonStore.shared.addons.count) addons")
                }
            } footer: {
                Text("Netflix-style browsing and streaming in Videos › Discover, using Nuvio/Stremio addon links.")
            }

            Section {
                Picker("Video Engine", selection: $engine) {
                    ForEach(VideoEngineChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Playback")
            } footer: {
                Text("Automatic uses Apple's player for MP4/MOV (with Picture in Picture) and VLC for MKV, AVI and everything else. Always VLC plays every file with VLC.")
            }

            Section {
                Toggle("Resume Where I Left Off", isOn: $resume)
                Toggle("Play Next Episode Automatically", isOn: $autoNext)
                Picker("Skip Buttons & Double-Tap", selection: $skipSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle("Swipe Left Side for Brightness", isOn: $brightnessGesture)
                Toggle("Swipe Right Side for Volume", isOn: $volumeGesture)
                Toggle("Swipe Sideways to Seek", isOn: $seekGesture)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Always on: double-tap to skip, pinch to fill the screen, hold for 2× speed.")
            }

            Section("Subtitles") {
                Picker("Preferred Language", selection: $language) {
                    Text("Arabic").tag("ar")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
                VStack(alignment: .leading) {
                    LabeledContent("Text Size", value: "\(Int(subtitleSize))")
                    Slider(value: $subtitleSize, in: 14...36, step: 1)
                }
                Toggle("Dark Background Behind Text", isOn: $subtitleBackground)
                Toggle("Yellow Text", isOn: $subtitleYellow)
            }

            Section {
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username (optional)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: username) { _, v in Keychain.set(v, for: "os.username") }
                SecureField("Password (optional)", text: $password)
                    .onChange(of: password) { _, v in Keychain.set(v, for: "os.password") }
            } header: {
                Text("Online Subtitles (OpenSubtitles)")
            } footer: {
                Text("Get a free API key at opensubtitles.com › Profile › API Consumers › New Consumer, and paste it here. Signing in raises the daily download limit. The password stays in the iPhone Keychain.")
            }
        }
        .navigationTitle("Videos & Player")
        .onAppear {
            username = Keychain.get("os.username") ?? ""
            password = Keychain.get("os.password") ?? ""
        }
    }
}