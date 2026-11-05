import AVFoundation
import EventKit
import SwiftUI

/// Reprise's permissions, docked beside System Settings while one of its privacy lists is open:
/// each one's state as it changes, and Reprise's icon hovering over the list for the ones that
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
    /// The icon is out over System Settings' list, so the one in the panel's header greys out.
    private(set) var iconOut = false

    private var panel: NSPanel?
    private var icon: NSPanel?
    private var follow: Task<Void, Never>?
    private var closing: NSObjectProtocol?

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
        if panel == nil { makePanels() }
        settingsFrame = nil // place again, and send the icon out over the list just opened
        if follow == nil { follow = Task { await run() } }
    }

    func close() {
        follow?.cancel()
        follow = nil
        closing.map(NotificationCenter.default.removeObserver)
        closing = nil
        let windows = [panel, icon]
        panel = nil
        icon = nil
        windows.forEach { $0?.close() }
        iconOut = false
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
            placeIcon(over: frame, shown: shown)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Windows

    private func makePanels() {
        let content = FirstClickHosting(rootView: AnyView(GuideView(guide: self)))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.hidesOnDeactivate = false // Reprise isn't the active app while System Settings is
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        // Starts where it was asked from, then moves aside to System Settings.
        let from = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: from.midX - panel.frame.width / 2, y: from.midY - panel.frame.height / 2))
        panel.orderFront(nil)
        self.panel = panel
        // Its close button puts the icon away too.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        let icon = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        icon.isOpaque = false
        icon.backgroundColor = .clear
        icon.hasShadow = false
        icon.level = .floating
        icon.hidesOnDeactivate = false
        icon.isReleasedWhenClosed = false
        icon.contentView = FirstClickHosting(rootView: AnyView(DragIcon()))
        self.icon = icon
    }

    private static let iconSize = 84.0

    private func dock(_ panel: NSPanel, beside frame: CGRect, animated: Bool) {
        let size = panel.frame.size, gap = 12.0
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? .infinite
        let x = frame.maxX + gap + size.width <= screen.maxX ? frame.maxX + gap : max(screen.minX, frame.minX - gap - size.width)
        let target = CGRect(origin: CGPoint(x: x, y: min(frame.maxY, screen.maxY) - size.height), size: size)
        animated ? panel.animator().setFrame(target, display: true) : panel.setFrame(target, display: true)
    }

    /// Over the top right of System Settings' list, flying out of the panel's header and back.
    private func placeIcon(over frame: CGRect, shown: Bool) {
        guard let icon, let panel else { return }
        let wanted = shown && active?.takesDrop == true && active.map(granted.contains) == false
        let header = CGRect(x: panel.frame.midX - Self.iconSize / 2, y: panel.frame.maxY - 22 - 32 - Self.iconSize / 2,
                            width: Self.iconSize, height: Self.iconSize)
        let spot = CGRect(x: frame.maxX - Self.iconSize - 28, y: frame.maxY - 52 - Self.iconSize + 8,
                          width: Self.iconSize, height: Self.iconSize)
        if wanted, !iconOut {
            icon.setFrame(header, display: false)
            icon.orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.45; icon.animator().setFrame(spot, display: true) }
        } else if wanted, icon.frame.origin != spot.origin {
            icon.setFrame(spot, display: true)
        } else if !wanted, iconOut {
            icon.orderOut(nil)
        }
        withAnimation(.smooth) { iconOut = wanted }
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
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .saturation(guide.iconOut ? 0 : 1)
                .opacity(guide.iconOut ? 0.35 : 1)
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
                    if guide.active == kind, kind.takesDrop, !guide.granted.contains(kind) {
                        Text("Drag the icon into the list").foregroundStyle(.tint)
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

/// Reprise's icon to drop on System Settings' list, bobbing gently so it reads as something to pick up.
private struct DragIcon: View {
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .offset(y: up ? -4 : 4)
            .frame(width: 84, height: 84)
            .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            .accessibilityLabel("Reprise")
            .accessibilityHint("Drag the icon into the list")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { up = true }
            }
    }
}
