import SwiftUI

/// A borderless, click-through-when-empty panel under the menu bar — home of the
/// Dynamic Island–style capsule. Drag the capsule anywhere; the spot is remembered.
///
/// Made each time the island shows, and closed once it's hidden: a window that has been on
/// screen, even ordered out, kept 0.6 MB, and the window server's notifications woke Reprise up
/// between calls. The capsule's view outlives the panels, so it animates in and out as before.
final class IslandPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "islandOrigin"

    static let size = CGSize(width: 520, height: 120)

    private static let content = NSHostingView(rootView: IslandView(model: .shared))
    private static var shown: IslandPanel?

    static func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shown?.reposition() }
        }
        NotificationCenter.default.addObserver(forName: .resetIslandPosition, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.removeObject(forKey: originKey)
                shown?.reposition()
            }
        }
        followIsland()
    }

    /// Only while there's something to show: nothing for the window server to composite.
    /// Never touch `ignoresMouseEvents`: once set (even to false), the clear parts of the
    /// panel stop letting clicks through to the windows below.
    private static func followIsland() {
        if AppModel.shared.island == .hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { // after the exit animation
                guard AppModel.shared.island == .hidden else { return }
                shown?.close()
                shown = nil
            }
        } else {
            if shown == nil { shown = IslandPanel() }
            shown?.orderFrontRegardless()
        }
        withObservationTracking { _ = AppModel.shared.island } onChange: {
            Task { @MainActor in followIsland() }
        }
    }

    private init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false // ARC owns it; close() must not release it again
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        sharingType = .none // keep the island out of screen shares and recordings
        #if DEBUG
        if DebugSnapshots.isRunning { sharingType = .readOnly } // but not out of the snapshot studio's
        #endif
        contentView = Self.content
        isMovableByWindowBackground = true
        delegate = self
        reposition()
    }

    override var canBecomeKey: Bool { false }

    func windowDidMove(_ notification: Notification) {
        if frame.origin != placed { UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey) } // only a drag picks a spot
    }

    /// Where Reprise itself last put the panel. `setFrameOrigin` posts `didMove` too, and
    /// remembering those spots would pin the island off-center after a display change.
    private var placed = CGPoint.zero

    private func reposition() {
        guard let origin = Self.origin() else { return }
        placed = origin
        setFrameOrigin(origin)
    }

    /// The remembered spot if it's still on a screen, otherwise centered under the menu bar.
    private static func origin() -> CGPoint? {
        if let saved = UserDefaults.standard.string(forKey: originKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(CGRect(origin: saved, size: size)) }) {
            return saved
        }
        return NSScreen.screens.first.map { CGPoint(x: ($0.frame.midX - size.width / 2).rounded(), y: ($0.visibleFrame.maxY - size.height).rounded()) }
    }

    #if DEBUG
    /// Where the island shows, for the snapshot studio to film it from before it does.
    static var frame: CGRect? { origin().map { CGRect(origin: $0, size: size) } }
    #endif
}

extension Notification.Name {
    static let resetIslandPosition = Notification.Name("resetIslandPosition")
}

struct IslandView: View {
    let model: AppModel
    /// The model's state a moment later. A new panel draws the island hidden first, so it animates
    /// in: the view put in a panel made for a state already set showed it at once, without the spring.
    @State private var island = IslandState.hidden
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One capsule whose size springs between states while its content cross-blurs.
        ZStack {
            if island != .hidden {
                ZStack {
                    switch island {
                    case .hidden:
                        EmptyView()
                    case .prompt(let app):
                        PromptContent(app: app, model: model)
                    case .recording:
                        RecordingContent(model: model)
                    case .saved(let recording):
                        SavedContent(recording: recording)
                    case .marked(let at):
                        Label("Marked at \(at.clock)", systemImage: "flag.fill")
                            .monospacedDigit()
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                    case .problem(let message):
                        let label = Label(message, systemImage: "exclamationmark.triangle.fill")
                        // Long warnings wrap onto a second line rather than run past the panel's edges.
                        ViewThatFits(in: .horizontal) {
                            label.fixedSize()
                            label.lineLimit(2).frame(width: 400)
                        }
                        .symbolRenderingMode(.multicolor)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                    }
                }
                .transition(.blurReplace)
                // Darkened like the Dynamic Island, so text reads over any wallpaper.
                .background(.black.opacity(0.38), in: .capsule)
                .glassEffect(.regular, in: .capsule)
                .gesture(WindowDragGesture())
                .transition(reduceMotion ? .opacity : .island)
            }
        }
        .padding(.top, 8)
        .frame(width: IslandPanel.size.width, height: IslandPanel.size.height, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.28), value: island)
        .task(id: model.island) { island = model.island }
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key) // the panel never becomes key; don't draw it dimmed
    }
}

private extension AnyTransition {
    /// Drops down from under the menu bar, slightly squashed and blurred.
    static var island: AnyTransition {
        .modifier(active: IslandEntrance(progress: 0), identity: IslandEntrance(progress: 1))
    }
}

private struct IslandEntrance: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.6 + 0.4 * progress, y: 0.4 + 0.6 * progress, anchor: .top)
            .offset(y: -24 * (1 - progress))
            .blur(radius: 10 * (1 - progress))
            .opacity(progress)
    }
}

// MARK: - States

private struct PromptContent: View {
    let app: MeetingApp
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(app: app, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.headline)
                Text(model.preroll == nil ? "Record this call?" : "Record from the start?")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 16)
            ScreenToggle(model: model)
            Button {
                Task { await model.startRecording(app: app) }
            } label: {
                Label("Record", systemImage: "record.circle.fill").fontWeight(.semibold)
            }
            .buttonStyle(CapsuleButtonStyle())
            .keyboardShortcut(.defaultAction)
            Button(action: model.dismissPrompt) {
                Image(systemName: "xmark").fontWeight(.semibold)
                    .overlay { CountdownRing(duration: AppModel.promptSeconds).frame(width: 26, height: 26) }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Not this time")
            .accessibilityLabel("Don't Record")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: 440, height: 54)
        .contentShape(.capsule)
        .contextMenu {
            Button("Always Record \(app.name)", systemImage: "record.circle") {
                app.rule = .always
                Task { await model.startRecording(app: app) }
            }
            Button("Ignore \(app.name)", systemImage: "nosign") {
                app.rule = .never
                model.dismissPrompt()
            }
            Divider()
            ResetPositionButton()
        }
    }
}

/// A solid capsule we draw ourselves: system bezels look dimmed in panels that aren't key.
struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(Color.red.gradient, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

private struct ScreenToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle(isOn: $model.recordScreen) {
            Image(systemName: model.recordScreen ? "rectangle.inset.filled.badge.record" : "rectangle.dashed.badge.record")
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(model.recordScreen ? "Recording the screen too" : "Also record the screen")
        .accessibilityLabel("Record the screen")
    }
}

/// Compact while you're on the call (two dots + timer); hover to see the stop button.
private struct RecordingContent: View {
    let model: AppModel
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Stopped, until "Saved" shows: nothing left to time or stop. The snapshot studio shows it with neither.
        let saving = model.session == nil && !model.saving.isEmpty
        let stoppable = expanded && !saving
        HStack(spacing: 10) {
            VoiceDots(levels: model.voices)
            if model.session?.screen != nil {
                Image(systemName: "rectangle.inset.filled").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if saving { Text("Saving…") } else { ElapsedTime(since: model.session?.recording.startedAt ?? .now) }
            }
            .font(.system(.body, design: .rounded).weight(.semibold))
            if stoppable {
                Button(action: model.mark) {
                    Image(systemName: "flag.fill").font(.caption)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Mark this moment")
                .accessibilityLabel("Mark This Moment")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill").font(.caption)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Stop recording")
                .accessibilityLabel("Stop Recording")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, stoppable ? 6 : 14)
        .frame(height: stoppable ? 40 : 32)
        .contentShape(.capsule)
        .onTapGesture(count: 2, perform: model.hidePill)
        .onHover { hovering in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.3)) { expanded = hovering }
        }
        #if DEBUG
        .task {
            guard DebugSnapshots.isRunning else { return }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { expanded = true }
        }
        #endif
        .contextMenu {
            if !saving {
                Button("Mark This Moment", systemImage: "flag", action: model.mark)
                Button("Stop Recording", systemImage: "stop.fill") { Task { await model.stopRecording() } }
                Button("Hide Until the Call Ends", systemImage: "eye.slash") { model.hidePill() }
                Divider()
            }
            ResetPositionButton()
        }
    }
}

private struct ResetPositionButton: View {
    var body: some View {
        Button("Move Back to the Top", systemImage: "arrow.up.to.line") {
            NotificationCenter.default.post(name: .resetIslandPosition, object: nil)
        }
    }
}

private struct SavedContent: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved").font(.headline)
                // What was saved, not just a number that could be a time of day.
                Text("\(recording.title) · \(recording.duration.clock)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Open") {
                AppModel.shared.selection = recording.id
                NotificationCenter.default.post(name: .openRepriseWindow, object: "library")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 48)
    }
}

// MARK: - Pieces

/// Plain digits once a second. Rolling ones (`numericText`) redrew the island at the display's
/// frame rate for half of every second: 7% CPU for the whole call.
struct ElapsedTime: View {
    let since: Date
    /// SwiftUI keeps a closed window's views, and their timelines go on: a library closed during a
    /// call kept ticking its clock until the call ended.
    @State private var onScreen = true

    var body: some View {
        Group {
            if onScreen {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(context.date.timeIntervalSince(since).clock).monospacedDigit()
                }
            } else {
                Text(Date.now.timeIntervalSince(since).clock).monospacedDigit()
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}

/// The logo's two dots, alive: the top one is you, the red one is everyone else.
/// Each lights up when its side speaks, so a glance shows that both sides are recorded.
///
/// Core Animation layers on a 15 Hz timer. As a SwiftUI timeline, every tick laid out and
/// redrew the whole island: 6% CPU for the whole call. Changing a layer's opacity costs nothing.
struct VoiceDots: NSViewRepresentable {
    let levels: () -> (you: Float, them: Float)

    func makeNSView(context: Context) -> DotsView { DotsView(levels: levels) }
    func updateNSView(_ view: DotsView, context: Context) { view.levels = levels }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsView, context: Context) -> CGSize? { CGSize(width: 7, height: 18) }

    final class DotsView: NSView {
        var levels: () -> (you: Float, them: Float)
        private let dots = [CALayer(), CALayer()]
        private var shown = [0.0, 0.0]
        /// `shown` in steps of 1/50, finer than the eye can tell: only a step redraws the island.
        private var drawn = [-1.0, -1.0]
        private var timer: Timer?

        init(levels: @escaping () -> (you: Float, them: Float)) {
            self.levels = levels
            super.init(frame: CGRect(x: 0, y: 0, width: 7, height: 18))
            wantsLayer = true
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel(String(localized: "Recording you and the other people"))
            for (dot, (color, y)) in zip(dots, [(NSColor.white, 11.0), (.systemRed, 0)]) {
                dot.frame = CGRect(x: 0, y: y, width: 7, height: 7)
                dot.cornerRadius = 3.5
                dot.backgroundColor = color.darkCGColor
                dot.shadowColor = color.darkCGColor
                dot.shadowOffset = .zero
                dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
                layer?.addSublayer(dot)
            }
            show()
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Ticks only while the dots can be seen: a call recorded with the display asleep or the
        /// screen locked ticked 15 times a second for nobody.
        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(follow), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            follow()
        }

        @objc private func follow() {
            guard window?.occlusionState.contains(.visible) == true else {
                timer?.invalidate()
                timer = nil
                return
            }
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.show() }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func show() {
            let peaks = levels()
            shown = [Self.follow(shown[0], peaks.you), Self.follow(shown[1], peaks.them)]
            let steps = shown.map { ($0 * 50).rounded() / 50 }
            // A level holding still, silence above all, leaves the glass alone: each change has the
            // window server composite the island anew.
            guard steps != drawn else { return }
            drawn = steps
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (dot, level) in zip(dots, steps) {
                dot.opacity = Float(0.4 + 0.6 * level)
                dot.shadowOpacity = Float(level)
                dot.shadowRadius = 4 * level
                dot.setAffineTransform(CGAffineTransform(scaleX: 1 + 0.25 * level, y: 1 + 0.25 * level))
            }
            CATransaction.commit()
        }

        /// Rises fast, falls slowly, like a VU meter, over a -50…0 dBFS window, where speech lives.
        private static func follow(_ current: Double, _ peak: Float) -> Double {
            let target = peak > 0 ? min(1, max(0, (20 * log10(Double(peak)) + 50) / 50)) : 0
            return current + (target - current) * (target > current ? 0.6 : 0.12)
        }
    }
}

/// The prompt's 20 seconds running out, animated by Core Animation itself: a SwiftUI timeline
/// redrew the whole island at the display's frame rate for as long as the prompt showed.
private struct CountdownRing: NSViewRepresentable {
    let duration: TimeInterval

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let ring = CAShapeLayer()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: 13, y: 13), radius: 13, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true) // from 12 o'clock
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = NSColor.secondaryLabelColor.darkCGColor
        ring.lineWidth = 1.5
        ring.lineCap = .round
        ring.strokeEnd = 0
        let shrink = CABasicAnimation(keyPath: "strokeEnd")
        shrink.fromValue = 1
        shrink.duration = duration
        shrink.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30) // 0.5 pt a step at most
        ring.add(shrink, forKey: nil)
        view.layer?.addSublayer(ring)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension NSColor {
    /// The island is always dark, and so is Welcome's tiny desktop.
    var darkCGColor: CGColor {
        var color = cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { color = cgColor }
        return color
    }
}

struct AppIcon: View {
    let app: MeetingApp?
    var size: CGFloat = 28

    var body: some View {
        // Manual recordings (no call app) wear Reprise's own icon.
        Image(nsImage: app?.icon ?? NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true) // decoration beside the text that names the app or the call
    }
}

extension TimeInterval {
    /// 0:42, 12:05, 1:02:33
    var clock: String {
        Duration.seconds(rounded(.down)).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
