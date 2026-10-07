import AppKit
import CoreAudio

struct MeetingApp: Hashable, Codable, Identifiable, Sendable {
    let id: String // bundle ID of the app the user sees
    let name: String

    var icon: NSImage? {
        if let cached = Self.icons[id] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.icons.updateValue(icon, forKey: id)
        return icon
    }

    /// Looked up once: list rows ask on every redraw, and each lookup goes to LaunchServices.
    private static var icons: [String: NSImage?] = [:]

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    var isKnownCallApp: Bool { Self.known.contains(self) }

    var isBrowser: Bool { Self.browsers.contains(self) }

    // The same app whatever language its name comes in.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var rule: Rule {
        get { UserDefaults.standard.string(forKey: Rule.key(id)).flatMap(Rule.init) ?? (Self.notCallApps.contains(id) ? .never : .ask) }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: Rule.key(id)) }
    }

    enum Rule: String, CaseIterable, Identifiable {
        case ask, always, never
        var id: Self { self }
        static func key(_ appID: String) -> String { "rule.\(appID)" }
        var title: String {
            switch self {
            case .ask: "Ask"
            case .always: "Always Record"
            case .never: "Ignore"
            }
        }
    }

    static let known = callApps + browsers

    private static let callApps: [MeetingApp] = [
        .init(id: "us.zoom.xos", name: "Zoom"),
        .init(id: "com.microsoft.teams2", name: "Microsoft Teams"),
        .init(id: "com.apple.FaceTime", name: "FaceTime"),
        .init(id: "com.tinyspeck.slackmacgap", name: "Slack"),
        .init(id: "com.hnc.Discord", name: "Discord"),
        .init(id: "Cisco-Systems.Spark", name: "Webex"),
        .init(id: "ru.keepcoder.Telegram", name: "Telegram"),
        .init(id: "org.telegram.desktop", name: "Telegram Desktop"),
        .init(id: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        .init(id: "org.whispersystems.signal-desktop", name: "Signal"),
        .init(id: "com.viber.osx", name: "Viber"),
        .init(id: "app.tuple.app", name: "Tuple"),
        .init(id: "Mattermost.Desktop", name: "Mattermost"),
        .init(id: "org.jitsi.jitsi-meet", name: "Jitsi Meet"),
        .init(id: "ru.yandex.desktop.telemost", name: "Yandex Telemost"),
    ]

    /// Google Meet and every other web call.
    private static let browsers: [MeetingApp] = [
        .init(id: "com.google.Chrome", name: "Google Chrome"),
        .init(id: "com.apple.Safari", name: "Safari"),
        .init(id: "company.thebrowser.Browser", name: "Arc"),
        .init(id: "company.thebrowser.dia", name: "Dia"),
        .init(id: "com.microsoft.edgemac", name: "Microsoft Edge"),
        .init(id: "com.brave.Browser", name: "Brave"),
        .init(id: "org.mozilla.firefox", name: "Firefox"),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        .init(id: "com.operasoftware.Opera", name: "Opera"),
        .init(id: "ru.yandex.desktop.yandex-browser", name: "Yandex Browser"),
        .init(id: "app.zen-browser.zen", name: "Zen"),
    ]

    /// Audio often runs in a helper process (`com.google.Chrome.helper`, Safari's
    /// `com.apple.WebKit.GPU`), so match by prefix and by known aliases.
    static func matching(processBundleID: String) -> MeetingApp? {
        let id = aliases[processBundleID] ?? processBundleID.lowercased()
        return known.first { id == $0.id.lowercased() || id.hasPrefix($0.id.lowercased() + ".") }
    }

    private static let aliases = [
        "com.apple.WebKit.GPU": "com.apple.safari",
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
    ]

    /// Apps that use the mic for things other than calls start out ignored.
    private static let notCallApps: Set = [
        "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX", "com.apple.PhotoBooth",
        "com.apple.garageband10", "com.apple.logic10",
    ]

    /// Other apps that have used the mic for a while — listed in Settings so they can get a rule.
    static var seen: [MeetingApp] {
        get { (UserDefaults.standard.data(forKey: "seenApps")).flatMap { try? JSONDecoder().decode([MeetingApp].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "seenApps") }
    }
}

/// Watches which apps are using the microphone and reports when a call starts or ends.
@Observable final class MeetingDetector {
    private(set) var active: Set<MeetingApp> = []
    var onStart: (MeetingApp) -> Void = { _ in }
    var onEnd: (MeetingApp) -> Void = { _ in }

    private var firstSeen: [MeetingApp: Date] = [:]
    private var lastSeen: [MeetingApp: Date] = [:]
    private var timer: Timer?
    private var watched: Set<AudioObjectID> = []
    /// Processes with audio going on, kept by their `IsRunning` notifications. A tick asks Core
    /// Audio about these few instead of every audio process: ~35 round trips took 10 ms.
    private var running: Set<AudioObjectID> = []
    /// The app of each running process: finding it takes round trips and LaunchServices.
    private var apps: [AudioObjectID: MeetingApp?] = [:]

    // ponytail: two fixed values; per-app tuning if some app's calls end with a long tail.
    /// How long an app may keep playing sound with the mic closed before its call counts as over.
    /// A call app doing that is muted (some close the mic on mute), and a long mute mustn't cut the
    /// recording in two. A browser may just be playing a video after the call, and Reprise holding
    /// the mic keeps headphones in call mode.
    private func endGrace(_ app: MeetingApp) -> TimeInterval { app.isBrowser ? 10 : 300 }

    /// Core Audio calls back when any app starts or stops audio, so between calls Reprise does no work.
    func start() {
        listen(.system, kAudioHardwarePropertyProcessObjectList)
        listen(.system, kAudioHardwarePropertyDevices)
        tick()
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tick(object) }
        }
    }

    /// Microphone use itself (`IsRunningInput`) sends no notifications. What does: a process
    /// starting or stopping its audio, and an input device getting a new client — an app that
    /// already plays sound and now opens the mic.
    private func watchNewObjects() -> [AudioObjectID] {
        let processes = AudioObjectID.system.ids(kAudioHardwarePropertyProcessObjectList)
        let devices = AudioObjectID.system.ids(kAudioHardwarePropertyDevices)
        watched.formIntersection(processes + devices) // gone objects take their listeners with them
        running.formIntersection(processes)
        for process in processes where watched.insert(process).inserted {
            listen(process, kAudioProcessPropertyIsRunning)
            recheck(process) // it may be playing already
        }
        // Output devices go into `watched` too, so their channels are only counted once.
        for device in devices where watched.insert(device).inserted && device.channelCount(scope: kAudioObjectPropertyScopeInput) > 0 {
            listen(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        return processes
    }

    private func recheck(_ process: AudioObjectID) {
        if process.get(kAudioProcessPropertyIsRunning, UInt32(0)) == 1 { running.insert(process) } else { running.remove(process) }
    }

    /// Every second while a call starts, runs or ends, for the delays below; the callbacks
    /// can't tell when a call app keeps playing sound after it closes the mic.
    private func schedule() {
        // ponytail: 30 s safety check in case a callback never comes; drop it once they prove complete.
        let interval: TimeInterval = firstSeen.isEmpty ? 30 : 1
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// `changed`: the object that sent a notification; none for the timer.
    private func tick(_ changed: AudioObjectID? = nil) {
        defer { schedule() }
        // The lists notify when they change; a call's timer ticks are only for the delays.
        let processes = changed == nil && !firstSeen.isEmpty ? [] : watchNewObjects()
        if changed == nil, firstSeen.isEmpty {
            processes.forEach(recheck) // between calls, the timer goes over all, in case a notification got lost
        } else {
            running.forEach(recheck) // a process that stops notifies too, but nothing depends on it
            if let changed, processes.contains(changed) { recheck(changed) }
        }
        let (audible, microphone) = audioApps()
        update(now: .now, microphone: microphone, audible: audible)
    }

    /// The call bookkeeping, apart from Core Audio so tests can drive it.
    func update(now: Date, microphone current: Set<MeetingApp>, audible: Set<MeetingApp>) {
        for app in current {
            firstSeen[app] = firstSeen[app] ?? now
            lastSeen[app] = now
            // Ignore quick mic checks; give unknown apps longer so dictation doesn't count as a call.
            let startDelay: TimeInterval = app.isKnownCallApp ? 2 : 10
            if !active.contains(app), now.timeIntervalSince(firstSeen[app]!) >= startDelay {
                active.insert(app)
                if !app.isKnownCallApp, !MeetingApp.seen.contains(app) { MeetingApp.seen.append(app) }
                onStart(app)
            }
        }
        for app in Set(firstSeen.keys).subtracting(current) {
            if !active.contains(app) {
                firstSeen[app] = nil // a blip that never became a call
            } else if !audible.contains(app) || now.timeIntervalSince(lastSeen[app] ?? now) >= endGrace(app) {
                // An app that mutes still plays the others; one gone silent has ended the call, so
                // the headphones get out of their call mode right away instead of after the grace.
                active.remove(app)
                firstSeen[app] = nil
                onEnd(app)
            }
        }
    }

    /// The apps of the processes with audio going on, and those of them that have the microphone open.
    private func audioApps() -> (audible: Set<MeetingApp>, microphone: Set<MeetingApp>) {
        var audible = Set<MeetingApp>(), microphone = Set<MeetingApp>()
        var found: [AudioObjectID: MeetingApp?] = [:]
        for process in running {
            let app = apps[process] ?? Self.app(of: process)
            found.updateValue(app, forKey: process)
            // Ignored apps aren't calls: no prompt, and no ticks every second while Logic holds the mic all day.
            // A call already going on is kept: Ignore set mid-call is for the next ones.
            guard let app, app.rule != .never || active.contains(app) else { continue }
            audible.insert(app)
            if process.get(kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 { microphone.insert(app) }
        }
        apps = found // a process looked up again when it starts again
        return (audible, microphone)
    }

    /// The app's audio processes, helpers included: what a tap needs to record only that app.
    static func processes(of app: MeetingApp) -> [AudioObjectID] {
        AudioObjectID.system.ids(kAudioHardwarePropertyProcessObjectList).filter { Self.app(of: $0) == app }
    }

    /// None for Reprise itself.
    private static func app(of process: AudioObjectID) -> MeetingApp? {
        let pid = process.get(kAudioProcessPropertyPID, pid_t(-1))
        guard pid != getpid() else { return nil }
        // Helpers share the process group of the app that launched them, so the group
        // leader tells Dia's "company.thebrowser.browser.helper" apart from Arc's.
        let owner = NSRunningApplication(processIdentifier: getpgid(pid))
        if let known = [owner?.bundleIdentifier, process.string(kAudioProcessPropertyBundleID)]
            .compactMap({ $0.flatMap(MeetingApp.matching) }).first {
            return known
        }
        // Any other regular app with the mic open might be a call too (VK, Lark, a new client…).
        guard let owner, owner.activationPolicy == .regular, let id = owner.bundleIdentifier else { return nil }
        return MeetingApp(id: id, name: owner.localizedName ?? id)
    }
}
