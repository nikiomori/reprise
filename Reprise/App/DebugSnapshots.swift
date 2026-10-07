#if DEBUG
import ScreenCaptureKit
import SwiftUI

/// A tiny photo studio for the README. `REPRISE_SNAPSHOTS=<dir>` shows every screen for a
/// moment in light and dark mode, captures it with ScreenCaptureKit (real Liquid Glass,
/// window shadows, transparent background), records the island animation, and quits.
/// Needs the Screen Recording permission. Pair with `REPRISE_ROOT` for demo data.
enum DebugSnapshots {
    static var isRunning: Bool { ProcessInfo.processInfo.environment["REPRISE_SNAPSHOTS"] != nil }

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["REPRISE_SNAPSHOTS"] else { return }
        let dir = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() } // e.g. Welcome
            NotificationCenter.default.post(name: .resetIslandPosition, object: nil)
            try? await Task.sleep(for: .seconds(0.5))
            await islandVideo(dir)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await islandStills(dir, name)
                await menu(dir, name)
                await window("library", dir, "library-\(name)")
                for tab in SettingsTab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
                    await window("settings", dir, "settings-\(tab.rawValue)-\(name)")
                }
                await window("welcome", dir, "welcome-\(name)")
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Island

    private static var island: NSWindow? { NSApp.windows.first { $0 is IslandPanel } }

    /// A clean gradient "desktop" behind the island, so no real wallpaper or menu bar leaks in.
    private static func backdrop(around frame: CGRect, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: frame.insetBy(dx: -40, dy: -40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; close() must not release it again
        window.level = .floating
        window.contentView = NSHostingView(rootView: LinearGradient(
            colors: dark ? [.indigo, .purple.mix(with: .black, by: 0.3)] : [.mint.mix(with: .white, by: 0.3), .blue.mix(with: .white, by: 0.2)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        window.orderFrontRegardless()
        return window
    }

    private static func islandStills(_ dir: URL, _ suffix: String) async {
        guard let island else { return }
        island.sharingType = .readOnly
        let backdrop = backdrop(around: island.frame, dark: suffix == "dark")
        defer { backdrop.close() }
        let model = AppModel.shared
        var states: [(String, IslandState)] = [
            ("prompt", .prompt(demoApp)),
            ("recording", .recording),
        ]
        if let recording = model.store.recordings.first { states.append(("saved", .saved(recording))) }
        for (name, state) in states {
            model.debugShow(state)
            try? await Task.sleep(for: .seconds(name == "recording" ? 3.5 : 1.5)) // let the pill expand
            await capture(rect: island.frame, dir, "island-\(name)-\(suffix)")
        }
        model.debugShow(.hidden)
        try? await Task.sleep(for: .seconds(0.8))
    }

    /// The whole story in one take: call detected → recording → saved.
    private static func islandVideo(_ dir: URL) async {
        guard let island, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        island.sharingType = .readOnly
        let backdrop = backdrop(around: island.frame, dark: true)
        defer { backdrop.close() }

        let height = NSScreen.screens[0].frame.height
        let rect = island.frame
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int(rect.width * 2)
        config.height = Int(rect.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        let output = SCRecordingOutputConfiguration()
        output.outputURL = dir.appending(path: "island.mov")
        output.outputFileType = .mov
        try? FileManager.default.removeItem(at: output.outputURL)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        let recorder = VideoDelegate()
        guard (try? stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: recorder))) != nil,
              (try? await stream.startCapture()) != nil else { return log.error("video failed") }

        let model = AppModel.shared
        try? await Task.sleep(for: .seconds(0.8))
        model.debugShow(.prompt(demoApp))
        try? await Task.sleep(for: .seconds(2.6))
        model.debugShow(.recording)
        try? await Task.sleep(for: .seconds(4.2))
        if let recording = model.store.recordings.first { model.debugShow(.saved(recording)) }
        try? await Task.sleep(for: .seconds(2.6))
        model.debugShow(.hidden)
        try? await Task.sleep(for: .seconds(1.2))
        try? await stream.stopCapture()
        try? await Task.sleep(for: .seconds(1))
    }

    private final class VideoDelegate: NSObject, SCRecordingOutputDelegate {}

    private static var demoApp: MeetingApp {
        MeetingApp.known.first { $0.id == "com.google.Chrome" && $0.isInstalled }
            .map { MeetingApp(id: $0.id, name: "Google Meet") } ?? MeetingApp.known.first { $0.isInstalled } ?? MeetingApp.known[0]
    }

    // MARK: Windows

    private static func window(_ id: String, _ dir: URL, _ name: String) async {
        if id == "library" { AppModel.shared.selection = AppModel.shared.store.recordings.first?.id }
        NotificationCenter.default.post(name: .openRepriseWindow, object: id)
        try? await Task.sleep(for: .seconds(2.5))
        let key = id == "settings" ? "Settings" : id // SwiftUI names windows after their scene ID
        guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue.contains(key) ?? false) }) else {
            return log.error("no window: \(id, privacy: .public); have \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" }, privacy: .public)")
        }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        await capture(window: window, dir, name)
        window.close()
        try? await Task.sleep(for: .seconds(0.6))
    }

    /// The real MenuBarExtra won't open from code, so show the same view in a lookalike panel.
    private static func menu(_ dir: URL, _ suffix: String) async {
        let host = NSHostingView(rootView: MenuBarView(model: .shared)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16)))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = host
        panel.center()
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        await capture(window: panel, dir, "menu-\(suffix)")
        panel.close()
    }

    // MARK: Capture

    private static func capture(window: NSWindow, _ dir: URL, _ name: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return log.error("capture failed: \(name, privacy: .public)") }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.ignoreShadowsSingleWindow = false
        config.showsCursor = false
        config.backgroundColor = .clear
        config.pixelFormat = kCVPixelFormatType_32BGRA
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return log.error("capture failed: \(name, privacy: .public)") }
        write(image, dir, name)
    }

    /// Captures a rect given in AppKit screen coordinates.
    private static func capture(rect frame: CGRect, _ dir: URL, _ name: String) async {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        guard let image = try? await SCScreenshotManager.captureImage(in: rect) else { return log.error("capture failed: \(name, privacy: .public)") }
        write(image, dir, name)
    }

    private static func write(_ image: CGImage, _ dir: URL, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}
#endif
