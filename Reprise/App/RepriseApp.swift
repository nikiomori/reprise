import AVFoundation
import SwiftUI

@main
struct RepriseApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage("onboarded") private var onboarded = false

    init() {
        UserDefaults.standard.register(defaults: ["showRecordingPill": true, Updater.autoKey: true])
        if isTesting {
            // The tests run inside the app: they get a scratch library, never the real one.
            setenv("REPRISE_ROOT", FileManager.default.temporaryDirectory.appending(path: "reprise-tests").path, 1)
        } else if ProcessInfo.processInfo.environment["REPRISE_ROOT"] == nil,
                  NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != getpid() }) {
            // A second copy on the same library would take the first one's recording in progress
            // for a crashed one and "repair" it away. A scratch library (`REPRISE_ROOT`) is fine.
            log.notice("Reprise is already running; this copy quits")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: .shared)
        } label: {
            MenuBarIcon(model: .shared)
        }
        .menuBarExtraStyle(.window)

        Window("Reprise", id: "library") {
            LibraryView(model: .shared)
                .showsInDock()
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified)
        .commands { RecordingCommands(model: .shared) }

        Window("Welcome to Reprise", id: "welcome") {
            WelcomeView()
                .showsInDock()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(onboarded ? .suppressed : .presented)

        Settings {
            SettingsView()
                .showsInDock()
        }
    }
}

/// File and Help menus: what a Mac app's menu bar is expected to offer while its window is open.
private struct RecordingCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { Task { await model.record() } }
                .keyboardShortcut("n")
                .disabled(model.session != nil)
            Button("Stop Recording") { Task { await model.stopRecording() } }
                .keyboardShortcut(".")
                .disabled(model.session == nil)
        }
        // Instead of the default item, which only says help isn't available.
        CommandGroup(replacing: .help) {
            Link("Reprise on GitHub", destination: URL(string: "https://github.com/nikiomori/reprise")!)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandPanel?
    private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        _ = Updater.shared
        island = IslandPanel()
        log.notice("Launched. Microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), screen: \(CGPreflightScreenCaptureAccess())")
        // `kill` and friends go through the normal quit, so a recording in progress gets saved.
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
    }

    /// Never lose a call: finish writing the file before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.session != nil || model.stopping != nil else { return .terminateNow }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.discardPrerollBeforeQuit()
    }
}

/// Lives in the menu bar for the app's whole life, so it also opens windows on behalf of
/// AppKit code (the island panel isn't part of a SwiftUI scene and can't call `openWindow`).
private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var now = Date.now

    var body: some View {
        // With the pill hidden, the menu bar keeps the call's time in sight.
        let since = model.pillHidden ? model.session?.recording.startedAt : nil
        Image(nsImage: .repriseGlyph(recording: model.session != nil, time: since.map { max(0, now.timeIntervalSince($0)).clock }))
            // Ticked by hand: a TimelineView in a menu bar label locks SwiftUI in an endless update at launch.
            .task(id: since) {
                guard let since else { return }
                while !Task.isCancelled {
                    now = .now
                    try? await Task.sleep(for: .seconds(1 - now.timeIntervalSince(since).truncatingRemainder(dividingBy: 1)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openRepriseWindow)) { note in
                let id = note.object as? String ?? "library"
                id == "settings" ? openSettings() : openWindow(id: id)
                NSApp.activate()
            }
    }
}

extension Notification.Name {
    /// Object: a window ID — "library", "welcome" or "settings".
    static let openRepriseWindow = Notification.Name("openRepriseWindow")
}

extension NSImage {
    /// The logo's repeat sign  :‖  sized for the menu bar. The lower dot — the other side of
    /// the call — turns red while recording; otherwise it's a template the system tints.
    /// `time` follows the sign in digits that keep their width: the menu bar ignores a label's font.
    static func repriseGlyph(recording: Bool, time: String? = nil) -> NSImage {
        let text = time.map { NSAttributedString(string: $0, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]) }
        let image = NSImage(size: NSSize(width: text.map { 20 + ceil($0.size().width) } ?? 15, height: 16), flipped: true) { _ in
            let ink = recording ? NSColor.labelColor : .black
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 4, width: 3.4, height: 3.4)).fill()
            NSBezierPath(roundedRect: NSRect(x: 5.6, y: 1, width: 1.6, height: 14), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 8.9, y: 1, width: 5.2, height: 14), xRadius: 1.4, yRadius: 1.4).fill()
            (recording ? NSColor.systemRed : ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 8.6, width: 3.4, height: 3.4)).fill()
            if let text { text.draw(at: NSPoint(x: 20, y: (16 - text.size().height) / 2)) }
            return true
        }
        image.isTemplate = !recording
        image.accessibilityDescription = recording ? "Reprise — recording" : "Reprise"
        return image
    }
}

private struct ShowsInDock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                // Back to a menu-bar-only app once the last window closes.
                DispatchQueue.main.async {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
    }
}

extension View {
    func showsInDock() -> some View { modifier(ShowsInDock()) }
}

/// Quits and opens a fresh copy — macOS only applies the Screen Recording permission to new launches.
func relaunch() {
    let reopen = Process()
    reopen.executableURL = URL(filePath: "/bin/sh")
    reopen.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath, "\(getpid())"]
    try? reopen.run()
    NSApp.terminate(nil)
}
