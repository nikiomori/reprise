import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Apps", systemImage: "app.badge.checkmark") { AppsSettings() }
            Tab("Transcription", systemImage: "text.bubble") { TranscriptionSettingsView() }
        }
        .scenePadding()
        .frame(width: 540)
        .frame(minHeight: 440)
    }
}

private struct GeneralSettings: View {
    @Bindable private var model = AppModel.shared
    @AppStorage("showRecordingPill") private var showPill = true
    @AppStorage("recordFromStart") private var recordFromStart = false
    @AppStorage("callAppAudioOnly") private var callAppAudioOnly = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screen = ScreenRecorder.hasPermission

    var body: some View {
        Form {
            Section {
                Toggle("Open Reprise at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Toggle("Record the screen by default", isOn: $model.recordScreen)
                Toggle("Show the floating pill while recording", isOn: $showPill)
                Toggle(isOn: $recordFromStart) {
                    Text("Record calls from the first second")
                    Text("While Reprise asks, it already records. Select Record to keep the call from the start. If you don't, Reprise deletes that audio.")
                }
                Toggle(isOn: $callAppAudioOnly) {
                    Text("Record only the sound of the call app")
                    Text("Music, videos, and notification sounds from other apps stay out of the audio. A recording you start yourself still gets all the sound of the Mac.")
                }
            }
            Section("Recordings") {
                LabeledContent("Saved in") {
                    Button(RecordingStore.root.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        AppModel.shared.store.revealInFinder()
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "Your side of the call", granted: microphone == .authorized, pane: "Privacy_Microphone")
                PermissionRow(title: "System audio", detail: "Everyone else — macOS asks the first time you record", granted: nil, pane: "Privacy_AudioCapture")
                PermissionRow(title: "Screen recording", detail: "Only if you record the screen", granted: screen, pane: "Privacy_ScreenCapture")
                if !screen, UserDefaults.standard.bool(forKey: "screenAccessRequested") {
                    LabeledContent("Already switched it on?") {
                        Button("Relaunch Reprise", action: relaunch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            screen = ScreenRecorder.hasPermission
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool?
    let pane: String

    var body: some View {
        LabeledContent {
            if granted == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.large)
            } else {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct AppsSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(MeetingApp.known.filter(\.isInstalled)) { app in
                    RuleRow(app: app)
                }
            } header: {
                Text("When a call starts in…")
            } footer: {
                Text("Browsers cover Google Meet and other web calls. Reprise notices a call when an app starts using the microphone.")
                    .foregroundStyle(.secondary)
            }
            let others = MeetingApp.seen
            if !others.isEmpty {
                Section("Other apps that used the microphone") {
                    ForEach(others) { RuleRow(app: $0) }
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

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: preset) {
                    Text("None").tag("None")
                    ForEach(TranscriptionService.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Custom").tag("Custom")
                }
                if !baseURL.isEmpty || preset.wrappedValue == "Custom" {
                    TextField("Server", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                    TextField("Model", text: $model)
                    SecureField("API key", text: $apiKey, prompt: Text("Not needed for local servers"))
                        .onChange(of: apiKey) { TranscriptionSettings.apiKey = apiKey }
                        .onChange(of: baseURL) { apiKey = TranscriptionSettings.apiKey ?? "" }
                    TextField("Language", text: $language, prompt: Text("Automatic, or a code like en or ru"))
                    Toggle("Transcribe calls automatically", isOn: $auto)
                }
            } footer: {
                Text("Reprise doesn't transcribe on its own yet. Any service with an OpenAI-compatible `/audio/transcriptions` endpoint works — including a whisper server on your own Mac, so audio never leaves it. The API key is kept in your Keychain.")
                    .foregroundStyle(.secondary)
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
