import AVFoundation
import ServiceManagement
import SwiftUI

/// Stored, so a button elsewhere can open Settings on the tab it's about.
enum SettingsTab: String, CaseIterable {
    case general, apps, transcription
    static let key = "settingsTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Apps", systemImage: "app.badge.checkmark", value: .apps) { AppsSettings() }
            Tab("Transcription", systemImage: "text.bubble", value: .transcription) { TranscriptionSettingsView() }
        }
        // Checkboxes, as in Safari's and Mail's settings: switches had macOS render their glass,
        // 307 MB at the window's opening for a moment, and 3 MB more kept after it closed.
        .toggleStyle(.checkbox)
        .frame(width: 540)
        .frame(maxHeight: 720) // a long list of apps scrolls instead of outgrowing the screen
        .fixedSize(horizontal: false, vertical: true) // each tab as tall as its content, like Apple's settings windows
    }
}

private struct GeneralSettings: View {
    @Bindable private var model = AppModel.shared
    @AppStorage("showRecordingPill") private var showPill = true
    @AppStorage("recordFromStart") private var recordFromStart = false
    @AppStorage("callAppAudioOnly") private var callAppAudioOnly = false
    @AppStorage("separateTracks") private var separateTracks = false
    @AppStorage(AppModel.sideFormatKey) private var sideFormat = "m4a"
    @AppStorage(CalendarEvents.key) private var calendarTitles = false
    @State private var calendars = CalendarEvents.isAllowed
    @AppStorage(Shortcut.key) private var shortcut = ""
    @AppStorage(RecordingStore.keepScreenKey) private var keepScreenDays = 0
    @State private var library = RecordingStore.root
    @State private var librarySize: Int64?
    @State private var shortcuts: [String] = []
    @AppStorage("screenAccessRequested") private var screenRequested = false
    @AppStorage("systemAudioHeard") private var systemAudioHeard = false
    @AppStorage(Updater.autoKey) private var checkForUpdates = true
    @State private var loginItem = SMAppService.mainApp.status
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screen = ScreenRecorder.hasPermission

    var body: some View {
        Form {
            Section {
                // The real state, not the last click: registering can fail or wait for approval.
                Toggle("Open Reprise at login", isOn: Binding {
                    loginItem == .enabled
                } set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    loginItem = SMAppService.mainApp.status
                })
                if loginItem == .requiresApproval {
                    LabeledContent {
                        Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Waiting for your approval")
                        Text("Allow Reprise in Login Items.")
                    }
                }
                LabeledContent {
                    Button("Show in Finder") { model.store.revealInFinder() }
                    Button("Change…", action: chooseLibrary)
                        .disabled(model.session != nil || model.preroll != nil || !model.saving.isEmpty) // never under a recording
                } label: {
                    Text("Saved in")
                    let path = library.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    Text(librarySize.map { "\(path) · \($0.formatted(.byteCount(style: .file)))" } ?? path)
                }
                .task(id: library) { librarySize = await RecordingStore.size(of: library) }
                Picker(selection: $keepScreenDays) {
                    Text("Forever").tag(0)
                    Text("3 Months").tag(90)
                    Text("1 Month").tag(30)
                    Text("1 Week").tag(7)
                } label: {
                    Text("Keep screen recordings")
                    Text("Older ones go to the Trash. Their calls stay, with the sound.")
                }
                .onChange(of: keepScreenDays) { model.store.trashOldScreens() }
            }
            Section("Recording") {
                Toggle(isOn: $recordFromStart) {
                    Text("Record calls from the first second")
                    Text("While Reprise asks, it already records. Select Record to keep the call from the start. If you don't, Reprise deletes that audio.")
                }
                Toggle(isOn: $callAppAudioOnly) {
                    Text("Record only the sound of the call app")
                    Text("Music, videos, and notification sounds from other apps stay out of the audio. A recording without a call still gets all the sound of the Mac.")
                }
                Toggle(isOn: $separateTracks) {
                    Text("Also save each side in its own file")
                    Text("You and the others, each in a file of its own next to the call, to edit a podcast or an interview. Without headphones, what your microphone heard of the others is taken out of your file after the call. Takes a little more power and disk space.")
                }
                if separateTracks {
                    Picker(selection: $sideFormat) {
                        Text("M4A").tag("m4a")
                        Text("WAV, uncompressed").tag("wav")
                    } label: {
                        Text("Format of each side")
                        Text("WAV keeps the sound as it was recorded, for editing, at about 350 MB an hour per side.")
                    }
                }
                Toggle(isOn: Binding {
                    calendarTitles
                } set: { on in
                    calendarTitles = on
                    if on { Task { calendars = await CalendarEvents.requestAccess() } }
                }) {
                    Text("Name calls after calendar events")
                    Text("A call gets the title of the event going on when it starts.")
                }
                Toggle("Record the screen by default", isOn: $model.recordScreen)
                Toggle("Show the floating pill while recording", isOn: $showPill)
            }
            Section {
                Picker("Run a shortcut", selection: $shortcut) {
                    Text("None").tag("")
                    Divider()
                    if !shortcut.isEmpty, !shortcuts.contains(shortcut) {
                        Text(shortcut).tag(shortcut) // renamed or deleted in Shortcuts since
                    }
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .task { shortcuts = await Shortcut.all() }
            } header: {
                Text("After Each Call")
            } footer: {
                Text("The shortcut gets the call's folder once it's saved, with its transcript if Reprise transcribes calls automatically. It can move the files, run a script on them, or send them on.")
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "Your side of the call", granted: microphone == .authorized, pane: "Privacy_Microphone",
                              allow: microphone != .notDetermined ? nil : {
                                  _ = await AVCaptureDevice.requestAccess(for: .audio)
                                  microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                              })
                // macOS can't be asked about this one; a recording that heard the other side proves it.
                PermissionRow(title: "System audio", detail: systemAudioHeard ? "Everyone else on the call" : "Everyone else — macOS asks the first time you record",
                              granted: systemAudioHeard ? true : nil, pane: "Privacy_AudioCapture")
                PermissionRow(title: "Screen recording", detail: "Only if you record the screen", granted: screen, pane: "Privacy_ScreenCapture",
                              allow: screenRequested ? nil : {
                                  screenRequested = true
                                  CGRequestScreenCaptureAccess()
                              })
                if calendarTitles {
                    PermissionRow(title: "Calendars", detail: "To name calls after their events", granted: calendars, pane: "Privacy_Calendars")
                }
                if !screen, screenRequested {
                    LabeledContent("Already switched it on?") {
                        Button("Relaunch Reprise", action: relaunch)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                UpdateRow(updater: .shared)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = SMAppService.mainApp.status
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            screen = ScreenRecorder.hasPermission
            calendars = CalendarEvents.isAllowed
        }
    }
}

extension GeneralSettings {
    /// A folder elsewhere: on another disk, in iCloud Drive, or on a server, as the user wants it kept.
    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = library
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Reprise saves new calls in this folder and shows the calls in it. The calls recorded so far stay where they are: to keep them in the library, move their folders here in Finder.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.store.useLibrary(at: folder)
        library = RecordingStore.root
    }
}

private struct UpdateRow: View {
    let updater: Updater

    var body: some View {
        LabeledContent {
            switch updater.state {
            case .checking, .installing:
                ProgressView().controlSize(.small)
            case .available(let release):
                Link("What's New", destination: release.html_url)
                Button("Install and Relaunch") { updater.install(release) }
                    .disabled(AppModel.shared.session != nil)
            case .failed(_, let release?):
                Link("Open GitHub", destination: release.html_url)
                Button("Try Again") { updater.install(release) }
            default:
                Button("Check Now") { Task { await updater.check() } }
            }
        } label: {
            switch updater.state {
            case .available(let release):
                Text("Reprise \(release.version) is available")
                Text(AppModel.shared.session == nil ? "You have \(Updater.current)." : "You can install it after the recording.")
            case .installing:
                Text("Installing the update…")
                Text("Reprise relaunches when it's done.")
            default:
                Text("Reprise \(Updater.current)")
                switch updater.state {
                case .checking: Text("Checking…")
                case .upToDate: Text("This is the latest version.")
                case .failed(let message, _): Text(message)
                default: EmptyView()
                }
            }
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool?
    let pane: String
    /// Asks macOS directly while it still can; once someone has answered, only System Settings changes it.
    var allow: (() async -> Void)?

    var body: some View {
        LabeledContent {
            if granted == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
                    .accessibilityLabel("Allowed")
            } else if let allow {
                Button("Allow") { Task { await allow() } }
            } else {
                Button("Open Settings") { Self.open(pane) }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    /// Opens the pane of Privacy & Security in System Settings.
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct AppsSettings: View {
    private let installed = MeetingApp.known.filter(\.isInstalled)

    var body: some View {
        Form {
            let callApps = installed.filter { !$0.isBrowser }
            if !callApps.isEmpty {
                Section {
                    ForEach(callApps) { RuleRow(app: $0) }
                } header: {
                    Text("Call Apps")
                } footer: {
                    Text("Reprise notices a call when one of these apps starts using the microphone.")
                        .foregroundStyle(.secondary)
                }
            }
            let browsers = installed.filter(\.isBrowser)
            if !browsers.isEmpty {
                Section {
                    ForEach(browsers) { RuleRow(app: $0) }
                } header: {
                    Text("Browsers")
                } footer: {
                    Text("For Google Meet and other calls on the web.")
                        .foregroundStyle(.secondary)
                }
            }
            let others = MeetingApp.seen
            if !others.isEmpty {
                Section {
                    ForEach(others) { RuleRow(app: $0) }
                } header: {
                    Text("Other Apps")
                } footer: {
                    Text("Apps that used the microphone for more than 10 seconds.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleRow: View {
    let app: MeetingApp
    @AppStorage private var rule: MeetingApp.Rule

    init(app: MeetingApp) {
        self.app = app
        _rule = AppStorage(wrappedValue: app.rule, MeetingApp.Rule.key(app.id))
    }

    var body: some View {
        Picker(selection: $rule) {
            ForEach(MeetingApp.Rule.allCases) { Text($0.title).tag($0) }
        } label: {
            HStack(spacing: 8) {
                AppIcon(app: app, size: 22)
                Text(app.name)
            }
        }
    }
}

private struct TranscriptionSettingsView: View {
    @AppStorage(TranscriptionSettings.baseURLKey) private var baseURL = ""
    @AppStorage(TranscriptionSettings.modelKey) private var model = ""
    @AppStorage(TranscriptionSettings.languageKey) private var language = ""
    @AppStorage(TranscriptionSettings.autoKey) private var auto = false
    @State private var apiKey = TranscriptionSettings.apiKey ?? ""
    @State private var refrainRunning = false

    /// Two-letter codes, which is what Whisper-style services take, named in the user's language.
    private static let languages = Locale.LanguageCode.isoLanguageCodes
        .filter { $0.identifier.count == 2 }
        .compactMap { code in Locale.current.localizedString(forLanguageCode: code.identifier).map { (code: code.identifier, name: $0) } }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: preset) {
                    Text("None").tag("None")
                    Divider()
                    ForEach(TranscriptionService.presets, id: \.name) { preset in
                        Label { Text(preset.name) } icon: { icon(of: preset) }.tag(preset.name)
                    }
                    Divider()
                    Label("Custom", systemImage: "network").tag("Custom")
                }
                if refrainRunning, baseURL != TranscriptionService.refrain.baseURL {
                    HStack {
                        Text("Refrain is running on this Mac")
                        Spacer()
                        Button("Use It") {
                            baseURL = TranscriptionService.refrain.baseURL
                            model = TranscriptionService.refrain.model
                        }
                    }
                }
            } footer: {
                Text("Reprise sends the audio to the service you choose. [Refrain](https://github.com/nikiomori/Refrain) transcribes it on this Mac, so the audio never leaves it; any other OpenAI-compatible service works too.")
                    .foregroundStyle(.secondary)
            }
            if !baseURL.isEmpty {
                Section {
                    TextField("Server", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                    TextField("Model", text: $model)
                    SecureField("API key", text: $apiKey, prompt: Text("Required, except for local servers"))
                        .onChange(of: apiKey) { TranscriptionSettings.apiKey = apiKey }
                        .onChange(of: baseURL) { apiKey = TranscriptionSettings.apiKey ?? "" }
                } footer: {
                    Text("The API key is kept in your Keychain.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("")
                        Divider()
                        if !Self.languages.contains(where: { $0.code == language }), !language.isEmpty {
                            Text(language).tag(language) // typed in by an earlier version
                        }
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    Toggle("Transcribe calls automatically", isOn: $auto)
                }
            }
        }
        .formStyle(.grouped)
        .task { refrainRunning = await TranscriptionService.refrainIsRunning() }
    }

    /// This Mac, a server nearby, or the service's own logo, named after it in the asset catalog.
    private func icon(of preset: (name: String, service: TranscriptionService)) -> Image {
        if preset.service.isRefrain { Image(systemName: "laptopcomputer") }
        else if preset.service.isLocal { Image(systemName: "server.rack") }
        else { Image(preset.name) }
    }

    private var preset: Binding<String> {
        Binding {
            if baseURL.isEmpty { return "None" }
            return TranscriptionService.presets.first { $0.service.baseURL == baseURL }?.name ?? "Custom"
        } set: { name in
            if let service = TranscriptionService.presets.first(where: { $0.name == name })?.service {
                baseURL = service.baseURL
                model = service.model
            } else if name == "None" {
                baseURL = ""
                model = ""
            } else if baseURL.isEmpty {
                baseURL = "https://"
            }
        }
    }
}
