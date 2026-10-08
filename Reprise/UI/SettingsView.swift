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
                    Button("Show in Finder") { AppModel.shared.store.revealInFinder() }
                } label: {
                    Text("Saved in")
                    Text(RecordingStore.root.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
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
                    Text("You and the others, as you.m4a and them.m4a next to the call, to edit a podcast or an interview. Takes a little more power and disk space.")
                }
                Toggle("Record the screen by default", isOn: $model.recordScreen)
                Toggle("Show the floating pill while recording", isOn: $showPill)
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
        }
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
    let title: String
    let detail: String
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
                    ForEach(TranscriptionService.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Divider()
                    Text("Custom").tag("Custom")
                }
            } footer: {
                Text("Reprise doesn't transcribe on the Mac yet. It sends the audio to the service you choose. Any OpenAI-compatible service works, including a Whisper server on your own Mac, so the audio never leaves it.")
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
