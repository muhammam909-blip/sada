import SwiftUI

/// Settings › Tabs: reorder, rename, turn Online on/off, Videos as its own tab.
struct TabSettingsView: View {
    @AppStorage(TabSettings.orderKey) private var orderRaw = TabSettings.defaultOrder
    @AppStorage(TabSettings.onlineKey) private var onlineEnabled = true
    @AppStorage(TabSettings.videosTabKey) private var videosSeparate = false
    @AppStorage("tabs.nameRevision") private var nameRevision = 0
    @State private var names: [AppTab: String] = [:]

    private var order: [AppTab] { TabSettings.order(orderRaw) }

    var body: some View {
        List {
            Section {
                Toggle("Online Music", isOn: $onlineEnabled)
                Toggle("Videos as a Separate Tab", isOn: $videosSeparate)
            } footer: {
                Text("Turn off Online Music to hide streaming, online search and recommendations. Without a separate Videos tab, movies & series live under Folders › Videos.")
            }

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
                        if (tab == .online && !onlineEnabled) || (tab == .videos && !videosSeparate) {
                            Text("Hidden").font(.caption).foregroundStyle(.secondary)
                        }
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
                Text("Drag to reorder. Tap a name to rename it; leave it empty for the default. Search always stays last.")
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

/// Settings › Videos: subtitles and the OpenSubtitles account.
struct VideoSettingsView: View {
    @AppStorage("subtitle.language") private var language = "ar"
    @AppStorage("subtitle.size") private var subtitleSize: Double = 20
    @AppStorage("os.apiKey") private var apiKey = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("Subtitles") {
                Picker("Preferred Language", selection: $language) {
                    Text("Arabic").tag("ar")
                    Text("English").tag("en")
                }
                VStack(alignment: .leading) {
                    LabeledContent("Text Size", value: "\(Int(subtitleSize))")
                    Slider(value: $subtitleSize, in: 14...36, step: 1)
                }
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
                Text("OpenSubtitles")
            } footer: {
                Text("Online subtitles need a free API key: sign up at opensubtitles.com, then open Profile › API Consumers › New Consumer and paste the key here. Signing in raises the daily download limit. Your password is kept in the iPhone Keychain.")
            }
            Section {
                LabeledContent("Plays now", value: "MP4, M4V, MOV")
                LabeledContent("Coming next", value: "MKV, AVI, WebM")
            } header: {
                Text("Formats")
            }
        }
        .navigationTitle("Videos")
        .onAppear {
            username = Keychain.get("os.username") ?? ""
            password = Keychain.get("os.password") ?? ""
        }
    }
}
