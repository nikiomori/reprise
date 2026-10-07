import SwiftUI

/// A borderless, click-through-when-empty panel under the menu bar — home of the
/// Dynamic Island–style capsule. Drag the capsule anywhere; the spot is remembered.
final class IslandPanel: NSPanel {
    private static let originKey = "islandOrigin"

    static let size = CGSize(width: 520, height: 120)

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        sharingType = .none // keep the island out of screen shares and recordings
        contentView = NSHostingView(rootView: IslandView(model: .shared))
        isMovableByWindowBackground = true
        reposition()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.frame.origin), forKey: Self.originKey)
            }
        }
        NotificationCenter.default.addObserver(forName: .resetIslandPosition, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.removeObject(forKey: Self.originKey)
                self?.reposition()
            }
        }
        orderFrontRegardless()
        followIsland()
    }

    override var canBecomeKey: Bool { false }

    /// Let clicks fall through while there's nothing to show.
    private func followIsland() {
        ignoresMouseEvents = AppModel.shared.island == .hidden
        withObservationTracking { _ = AppModel.shared.island } onChange: { [weak self] in
            Task { @MainActor in self?.followIsland() }
        }
    }

    /// The remembered spot if it's still on a screen, otherwise centered under the menu bar.
    private func reposition() {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(CGRect(origin: saved, size: Self.size)) }) {
            return setFrameOrigin(saved)
        }
        guard let screen = NSScreen.screens.first else { return }
        setFrameOrigin(CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.visibleFrame.maxY - Self.size.height))
    }
}

extension Notification.Name {
    static let resetIslandPosition = Notification.Name("resetIslandPosition")
}

struct IslandView: View {
    let model: AppModel

    var body: some View {
        // One capsule whose size springs between states while its content cross-blurs.
        ZStack {
            if model.island != .hidden {
                ZStack {
                    switch model.island {
                    case .hidden:
                        EmptyView()
                    case .prompt(let app):
                        PromptContent(app: app, model: model)
                    case .recording:
                        RecordingContent(model: model)
                    case .saved(let recording):
                        SavedContent(recording: recording)
                    case .problem(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                    }
                }
                .transition(.blurReplace)
                // Darkened like the Dynamic Island, so text reads over any wallpaper.
                .background(.black.opacity(0.38), in: .capsule)
                .glassEffect(.regular, in: .capsule)
                .gesture(WindowDragGesture())
                .transition(.island)
            }
        }
        .padding(.top, 8)
        .frame(width: IslandPanel.size.width, height: IslandPanel.size.height, alignment: .top)
        .animation(.spring(duration: 0.5, bounce: 0.28), value: model.island)
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
    @State private var appeared = Date.now
    private let timeout: TimeInterval = 20

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
                    .overlay {
                        TimelineView(.animation) { context in
                            Circle()
                                .trim(from: 0, to: max(0, 1 - context.date.timeIntervalSince(appeared) / timeout))
                                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 26, height: 26)
                        }
                    }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Not this time")
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
            Button("Never Ask for \(app.name)", systemImage: "nosign") {
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
    var color: Color = .red
    var padding = EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(padding)
            .background(color.gradient, in: .capsule)
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
                .contentTransition(.symbolEffect(.replace))
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(model.recordScreen ? "Recording the screen too" : "Also record the screen")
    }
}

/// Compact while you're on the call (two dots + timer); hover to see the level and the stop button.
private struct RecordingContent: View {
    let model: AppModel
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 10) {
            VoiceDots(levels: model.voices)
            if model.session?.screen != nil {
                Image(systemName: "rectangle.inset.filled").font(.caption).foregroundStyle(.secondary)
            }
            ElapsedTime(since: model.session?.recording.startedAt ?? .now)
            if expanded {
                LevelMeter(level: model.level)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill").font(.caption)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Stop recording")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, expanded ? 6 : 14)
        .frame(height: expanded ? 40 : 32)
        .contentShape(.capsule)
        .onHover { hovering in
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { expanded = hovering }
        }
        #if DEBUG
        .task {
            guard DebugSnapshots.isRunning else { return }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { expanded = true }
        }
        #endif
        .contextMenu {
            Button("Stop Recording", systemImage: "stop.fill") { Task { await model.stopRecording() } }
            Button("Hide Until the Call Ends", systemImage: "eye.slash") { model.hidePill() }
            Divider()
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
    @State private var drawn = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .symbolEffect(.drawOn, isActive: !drawn)
                .onAppear { drawn = true }
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved").font(.headline)
                Text(recording.duration.clock).font(.caption).foregroundStyle(.secondary)
            }
            Button("Open") {
                AppModel.shared.selection = recording.id
                NotificationCenter.default.post(name: .openRepriseWindow, object: "library")
            }
            .buttonStyle(.glass)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 48)
    }
}

// MARK: - Pieces

struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(context.date.timeIntervalSince(since).clock)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(context.date.timeIntervalSince(since)))
        }
    }
}

/// Five bars that dance with the call's loudness.
struct LevelMeter: View {
    let level: () -> Float
    @State private var smoothed: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: 4 + 16 * smoothed * wobble)
                }
            }
            .frame(height: 20)
            .onChange(of: context.date) { smoothed = Self.follow(smoothed, level()) }
        }
    }

    /// Rises fast, falls slowly, like a VU meter.
    static func follow(_ current: Double, _ peak: Float) -> Double {
        let target = normalize(peak)
        return current + (target - current) * (target > current ? 0.6 : 0.12)
    }

    /// dBFS → 0...1 over a -50…0 dB window, which is where speech lives.
    static func normalize(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(peak)) + 50) / 50))
    }
}

/// The logo's two dots, alive: the top one is you, the red one is everyone else.
/// Each lights up when its side speaks, so a glance shows that both sides are recorded.
struct VoiceDots: View {
    let levels: () -> (you: Float, them: Float)
    @State private var you = 0.0
    @State private var them = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            VStack(spacing: 4) {
                dot(.white, you)
                dot(.red, them)
            }
            .onChange(of: context.date) {
                let peaks = levels()
                you = LevelMeter.follow(you, peaks.you)
                them = LevelMeter.follow(them, peaks.them)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording you and the other people")
    }

    private func dot(_ color: Color, _ level: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(0.4 + 0.6 * level)
            .shadow(color: color.opacity(level), radius: 4 * level)
            .scaleEffect(1 + 0.25 * level)
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
    }
}

extension TimeInterval {
    /// 0:42, 12:05, 1:02:33
    var clock: String {
        Duration.seconds(rounded(.down)).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
