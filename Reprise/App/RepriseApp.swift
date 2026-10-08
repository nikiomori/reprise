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

/// File and Help menus, and Find…: what a Mac app's menu bar is expected to offer while its window is open.
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
        // In the Edit menu, where Mail and Notes have it. `TextEditingCommands`' Find… doesn't reach the search field.
        CommandGroup(after: .textEditing) {
            Button("Find…") { NotificationCenter.default.post(name: .findCalls, object: nil) }
                .keyboardShortcut("f")
        }
        // Instead of the default item, which only says help isn't available.
        CommandGroup(replacing: .help) {
            Link("Reprise on GitHub", destination: URL(string: "https://github.com/nikiomori/reprise")!)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        _ = Updater.shared
        IslandPanel.start()
        log.notice("Launched. Microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), screen: \(CGPreflightScreenCaptureAccess())")
        // `kill` and friends go through the normal quit, so a recording in progress gets saved.
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler { quit() }
        termination.resume()
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
    }

    /// Never lose a call: finish writing the file before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.session != nil || !model.saving.isEmpty else { return .terminateNow }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opened again from Finder or Spotlight while running: show a window, as the menu bar item
    /// may be out of reach (behind the notch, or hidden in System Settings). Not `hasVisibleWindows`,
    /// which may count the recording pill.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !sender.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            NotificationCenter.default.post(name: .openRepriseWindow, object: UserDefaults.standard.bool(forKey: "onboarded") ? "library" : "welcome")
        }
        return true
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
    /// Edit > Find…: to the library's search field.
    static let findCalls = Notification.Name("findCalls")
}

extension NSImage {
    /// The logo's repeat sign  :‖  sized for the menu bar. The lower dot — the other side of
    /// the call — turns red and the wide bar fills while recording; otherwise it's a template the system tints.
    /// `time` follows the sign in digits that keep their width: the menu bar ignores a label's font.
    static func repriseGlyph(recording: Bool, time: String? = nil) -> NSImage {
        let text = time.map { NSAttributedString(string: $0, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]) }
        let image = NSImage(size: NSSize(width: text.map { 20 + ceil($0.size().width) } ?? 15, height: 16), flipped: true) { _ in
            let ink = recording ? NSColor.labelColor : .black
            ink.setFill()
            ink.setStroke()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 4.9, width: 2.8, height: 2.8)).fill()
            NSBezierPath(roundedRect: NSRect(x: 5.6, y: 2, width: 1.4, height: 12), xRadius: 0.7, yRadius: 0.7).fill()
            // Hollow while waiting, as light as the system's symbols next to it: filled, it was
            // the heaviest thing in the menu bar all day. Filled while recording.
            if recording {
                NSBezierPath(roundedRect: NSRect(x: 8.55, y: 1.95, width: 4.7, height: 12.1), xRadius: 1.4, yRadius: 1.4).fill()
            } else {
                let bar = NSBezierPath(roundedRect: NSRect(x: 9.1, y: 2.5, width: 3.6, height: 11), xRadius: 0.9, yRadius: 0.9)
                bar.lineWidth = 1.1
                bar.stroke()
            }
            (recording ? NSColor.systemRed : ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 8.3, width: 2.8, height: 2.8)).fill()
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
                // Back to a menu-bar-only app once the last window closes. A minimized one isn't
                // visible, but its Dock tile goes with the app's icon.
                DispatchQueue.main.async {
                    if !NSApp.windows.contains(where: { ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled) }) {
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
    quit()
}

/// Quits from the run loop, never from inside a block on the main queue (a Task, a dispatch source):
/// a quit that waits for a recording to be saved runs the run loop until it is, and that block would
/// hold up the main queue, and the save with it. Reprise hung for good, still recording.
func quit() {
    NSApp.perform(#selector(NSApplication.terminate), with: nil, afterDelay: 0)
}
