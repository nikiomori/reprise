import AVFoundation
import EventKit
import SwiftUI

/// Reprise's permissions, docked beside System Settings while one of its privacy lists is open:
/// each one's state as it changes, and Reprise's icon in its header to drag into the lists that
/// take an app dropped on them. Nobody hunts for the app or wonders whether it worked.
@Observable final class PermissionGuide {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone = "Privacy_Microphone", systemAudio = "Privacy_AudioCapture"
        case screen = "Privacy_ScreenCapture", calendars = "Privacy_Calendars"
        var id: Self { self }
    }

    static let shared = PermissionGuide()
    private(set) var active: Kind?
    private(set) var granted: Set<Kind> = []
    /// The list open in System Settings waits for Reprise's icon.
    var wantsDrop: Bool { active.map { $0.takesDrop && !granted.contains($0) } ?? false }

    private var panel: NSPanel?
    private var follow: Task<Void, Never>?
    private var closing: NSObjectProtocol?
    /// Reprise's own windows, out of the way while the guide is up.
    private var hidden: [NSWindow] = []

    func open(_ kind: Kind) {
        active = kind
        refresh()
        // Asked straight away while macOS still asks; after that only System Settings changes it.
        if kind == .microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() }
            return
        }
        if kind == .calendars, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            Task { _ = await CalendarEvents.requestAccess(); refresh() }
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.rawValue)")!)
        if panel == nil {
            makePanel()
            // The guide takes the place of the window it was asked from. Picking the icon up makes
            // Reprise the active app, and macOS brings its windows forward: the welcome window or
            // Settings covered the list and caught the drop.
            hidden = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            hidden.forEach { $0.orderOut(nil) }
        }
        settingsFrame = nil // place again beside the list just opened
        if follow == nil { follow = Task { await run() } }
    }

    func close() {
        follow?.cancel()
        follow = nil
        closing.map(NotificationCenter.default.removeObserver)
        closing = nil
        let panel = panel
        self.panel = nil
        panel?.close()
        hidden.forEach { $0.orderFront(nil) }
        hidden = []
        active = nil
    }

    // MARK: - State

    private func refresh() {
        granted = Set(Kind.allCases.filter(\.isGranted))
    }

    private var settingsFrame: CGRect?

    private func run() async {
        var waited = 0
        // ponytail: polls twice a second only while the guide is up; AX observers if it ever matters.
        while !Task.isCancelled, let panel {
            let was = granted
            refresh()
            if let active, granted.contains(active), !was.contains(active) {
                AccessibilityNotification.Announcement("Allowed").post()
            }
            guard let frame = Self.systemSettingsFrame() else {
                waited += 1
                // System Settings closed, or never opened within 10 s.
                if settingsFrame != nil || waited > 20 { return close() }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            waited = 0
            if frame != settingsFrame { // follow System Settings when it moves; leave the panel alone otherwise
                let first = settingsFrame == nil
                settingsFrame = frame
                dock(panel, beside: frame, animated: first)
            }
            // Over System Settings only, not over whatever app the user turned to. The password
            // prompt for the change comes from a background process: stay through it.
            let front = NSWorkspace.shared.frontmostApplication
            let shown = front?.activationPolicy != .regular || [Self.settingsID, Bundle.main.bundleIdentifier].contains(front?.bundleIdentifier)
            shown ? panel.orderFront(nil) : panel.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Windows

    private func makePanel() {
        let content = FirstClickHosting(rootView: AnyView(GuideView(guide: self)))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.hidesOnDeactivate = false // Reprise isn't the active app while System Settings is
        // Never key: a nonactivating panel that is takes the keyboard from System Settings, and the
        // password typed into its prompt for the dropped icon went to Reprise.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        // Starts where it was asked from, then moves aside to System Settings.
        let from = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: from.midX - panel.frame.width / 2, y: from.midY - panel.frame.height / 2))
        panel.orderFront(nil)
        self.panel = panel
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func dock(_ panel: NSPanel, beside frame: CGRect, animated: Bool) {
        let size = panel.frame.size, gap = 12.0
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? .infinite
        let x = frame.maxX + gap + size.width <= screen.maxX ? frame.maxX + gap : max(screen.minX, frame.minX - gap - size.width)
        let target = CGRect(origin: CGPoint(x: x, y: min(frame.maxY, screen.maxY) - size.height), size: size)
        animated ? panel.animator().setFrame(target, display: true) : panel.setFrame(target, display: true)
    }

    private static let settingsID = "com.apple.systempreferences"

    /// System Settings' main window in AppKit's coordinates. Window bounds need no permission; titles would.
    private static func systemSettingsFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let bounds = windows
            .filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary) }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let bounds, let top = NSScreen.screens.first?.frame.maxY else { return nil }
        return CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

extension PermissionGuide.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .screen: "Screen recording"
        case .calendars: "Calendars"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .microphone: "Your side of the call"
        case .systemAudio: "Everyone else on the call"
        case .screen: "Only if you record the screen"
        case .calendars: "To name calls after their events"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        case .screen: "rectangle.inset.filled.badge.record"
        case .calendars: "calendar"
        }
    }

    /// These lists take an app dropped on them; the others list it once it has asked.
    var takesDrop: Bool { self == .screen || self == .systemAudio }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // The live answer: CGPreflightScreenCaptureAccess turns true only after a relaunch, and
        // system audio has no public question at all.
        case .systemAudio: TCC.preflight("kTCCServiceAudioCapture") ?? UserDefaults.standard.bool(forKey: "systemAudioHeard")
        case .screen: TCC.preflight("kTCCServiceScreenCapture") ?? ScreenRecorder.hasPermission
        case .calendars: CalendarEvents.isAllowed
        }
    }
}

/// macOS's own answer to whether a privacy permission is on, from the private TCC framework;
/// nil if it ever goes away. ponytail: private API, fall back to the public checks if it breaks.
private enum TCC {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private static let function: Preflight? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY)
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: Preflight.self) }

    static func preflight(_ service: String) -> Bool? { function.map { $0(service as CFString, nil) == 0 } }
}

/// A drag or click can start on the first click, while System Settings is the active app.
private final class FirstClickHosting: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct GuideView: View {
    let guide: PermissionGuide
    @AppStorage(CalendarEvents.key) private var calendarTitles = false

    var body: some View {
        VStack(spacing: 14) {
            // Picked up right here, where the eye already is; it bobs while the open list waits for it.
            DraggableIcon(bobbing: guide.wantsDrop)
                .frame(width: 84, height: 84)
                .padding(-10)
            Text("Permissions").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(PermissionGuide.Kind.allCases.filter { $0 != .calendars || calendarTitles }) { kind in
                    if kind != .microphone { Divider().padding(.leading, 44) }
                    row(kind)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        }
        .frame(width: 360)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .animation(.smooth, value: guide.granted)
        .animation(.smooth, value: guide.active)
    }

    private func row(_ kind: PermissionGuide.Kind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).fontWeight(.medium)
                Group {
                    if guide.active == kind, guide.wantsDrop {
                        Text("Drag the icon above into the list").foregroundStyle(.tint)
                    } else {
                        Text(kind.detail).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            if guide.granted.contains(kind) {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: .capsule)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…") { guide.open(kind) }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct DraggableIcon: NSViewRepresentable {
    let bobbing: Bool
    func makeNSView(context: Context) -> DragIcon { DragIcon() }
    func updateNSView(_ view: DragIcon, context: Context) { view.bobbing = bobbing }
}

/// Reprise's icon to drop on System Settings' list, bobbing gently so it reads as something to pick up.
/// An AppKit drag that puts the app's file URL on the pasteboard up front, as Finder does: System
/// Settings reads it only after the password prompt, when the drag is over, and SwiftUI's onDrag
/// offered it lazily through an item provider, gone by then. The prompt passed, nothing was added.
final class DragIcon: NSView, NSDraggingSource {
    private let image = NSApp.applicationIconImage ?? NSImage()
    private let icon = CALayer()
    var bobbing = false { didSet { if bobbing != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contents = image
        icon.contentsGravity = .resizeAspect
        icon.shadowOpacity = 0.3
        icon.shadowRadius = 6
        icon.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Reprise")
        setAccessibilityHelp(String(localized: "Drag the icon above into the list"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 10, dy: 10)
        guard bobbing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return icon.removeAnimation(forKey: "bob") }
        guard icon.animation(forKey: "bob") == nil else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -4
        bob.toValue = 4
        bob.duration = 1.1
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.add(bob, forKey: "bob")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {} // a drag starts on the first move

    override func mouseDragged(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(Bundle.main.bundleURL.absoluteString, forType: .fileURL)
        item.setPropertyList([Bundle.main.bundlePath], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(icon.frame, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}
