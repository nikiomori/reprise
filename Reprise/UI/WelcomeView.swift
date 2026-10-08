import AVFoundation
import ServiceManagement
import SwiftUI

struct WelcomeView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var audio = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenGranted = ScreenRecorder.hasPermission
    @AppStorage("screenAccessRequested") private var screenRequested = false
    @State private var launchAtLogin = true
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Demo()
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: 18))
                .padding(10)

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.bottom, 4)
                Text("Reprise").font(.system(size: 30, weight: .bold))
                Text("Be present. Reprise remembers.").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            VStack(spacing: 4) {
                Step(icon: "mic.fill", tint: .red, title: "Microphone and system audio",
                     detail: "So both sides of the call end up in the recording.", done: audio == .authorized,
                     actionTitle: audio == .notDetermined ? "Allow" : "Open Settings") {
                    await requestAudio()
                }
                // macOS applies this permission only after a relaunch.
                Step(icon: "rectangle.inset.filled.badge.record", tint: .blue, title: "Screen recording",
                     detail: screenRequested && !screenGranted ? "Switched it on? Relaunch to finish." : "Optional, for recording the screen.",
                     done: screenGranted, actionTitle: screenRequested ? "Relaunch" : "Allow") {
                    if screenRequested {
                        relaunch()
                    } else {
                        screenRequested = true
                        CGRequestScreenCaptureAccess()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            VStack(spacing: 14) {
                Button("Continue", action: finish)
                    .buttonStyle(.glassProminent)
                    .tint(.red) // Reprise's one accent, the way Voice Memos keeps its own
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                Toggle("Open Reprise at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 520)
        .onAppear { withAnimation(.spring(duration: 0.8).delay(0.15)) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = ScreenRecorder.hasPermission
            audio = AVCaptureDevice.authorizationStatus(for: .audio) // switched on in System Settings
        }
    }

    private func requestAudio() async {
        // Once answered, macOS doesn't ask again: only System Settings changes it.
        guard audio == .notDetermined else { return PermissionRow.open("Privacy_Microphone") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { audio = .denied; return }
        // A blink of a recording makes macOS ask for system-audio access now rather than mid-call.
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-probe.m4a")
        let probe = AudioRecorder(url: url)
        await Task.detached {
            try? probe.start()
            try? await Task.sleep(for: .milliseconds(600))
            probe.stop()
            try? FileManager.default.removeItem(at: url)
        }.value
        withAnimation(.spring) { audio = .authorized }
    }

    private func finish() {
        if launchAtLogin { try? SMAppService.mainApp.register() }
        onboarded = true
        dismissWindow()
    }
}

private struct Step: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let done: Bool
    var actionTitle: LocalizedStringKey = "Allow"
    let action: () async -> Void

    var body: some View {
        HStack(spacing: 14) {
            // A tinted symbol, the way Apple's own Mac apps list what they need on first launch.
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(actionTitle) { Task { await action() } }
                    .buttonStyle(.glass)
                    .contentTransition(.interpolate)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.spring(duration: 0.4, bounce: 0.35), value: done)
        .animation(.smooth, value: actionTitle)
    }
}

/// A tiny desktop that plays the whole story on loop: call → record → saved.
private struct Demo: View {
    @State private var stage = 0
    /// SwiftUI keeps a closed window's views, and their tasks go on: closed after onboarding, the
    /// demo went on playing its story until Reprise quit.
    @State private var onScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop(drifts: !reduceMotion)
            Rectangle().fill(.black.opacity(0.18)).frame(height: 22)

            capsule
                .padding(.top, 30)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.3), value: stage)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: onScreen) {
            while onScreen, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(stage == 3 ? 1.2 : 2.4))
                stage = (stage + 1) % 4
            }
        }
    }

    @ViewBuilder private var capsule: some View {
        if stage != 3 {
            ZStack {
                switch stage {
                case 0:
                    HStack(spacing: 10) {
                        AppIcon(app: MeetingApp.known.first { $0.id == "com.google.Chrome" }, size: 24)
                        Text("Google Meet · Record this call?").font(.callout.weight(.medium))
                        Text("Record").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.red, in: .capsule)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                case 1:
                    HStack(spacing: 8) {
                        VoiceDots { (.random(in: 0...0.3), .random(in: 0.1...0.6)) }
                        Text("0:12").font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                default:
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .symbolRenderingMode(.multicolor)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
            }
            .transition(.blurReplace)
            .glassEffect(.regular, in: .capsule)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.5, anchor: .top).combined(with: .opacity))
        }
    }
}

/// The tiny desktop's colors, the center one drifting: gradient layers, moved by Core Animation
/// itself. A MeshGradient took 260 MB of graphics memory as it first drew and kept 7 MB, and its
/// timeline redrew the window 30 times a second.
private struct Backdrop: NSViewRepresentable {
    let drifts: Bool

    func makeNSView(context: Context) -> Layers { Layers(drifts: drifts) }
    func updateNSView(_ view: Layers, context: Context) {}

    final class Layers: NSView {
        private let middle = CAGradientLayer(), top = CAGradientLayer(), bottom = CAGradientLayer(), glow = CAGradientLayer()
        private let drifts: Bool

        init(drifts: Bool) {
            self.drifts = drifts
            super.init(frame: .zero)
            wantsLayer = true
            // The rows of a 3 × 3 mesh: each a gradient across, the top and bottom ones fading out
            // towards the middle row, and a glow where the mesh's center point was.
            for (layer, colors) in [(middle, [NSColor.systemBlue, .systemPink, .systemRed]),
                                    (top, [.systemIndigo, .systemPurple, .systemPink]),
                                    (bottom, [.systemTeal, .systemIndigo, .systemPurple])] {
                layer.colors = colors.map(\.darkCGColor)
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
                self.layer?.addSublayer(layer)
            }
            for (band, from, to) in [(top, 1.0, 0.45), (bottom, 0.0, 0.55)] {
                let fade = CAGradientLayer()
                fade.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
                fade.startPoint = CGPoint(x: 0.5, y: from)
                fade.endPoint = CGPoint(x: 0.5, y: to)
                band.mask = fade
            }
            let orange = NSColor.systemOrange.blended(withFraction: 0.4, of: .systemPink) ?? .systemOrange
            glow.type = .radial
            glow.colors = [orange.darkCGColor, orange.withAlphaComponent(0).darkCGColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(glow)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [middle, top, bottom] {
                layer.frame = bounds
                layer.mask?.frame = bounds
            }
            glow.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.7, height: bounds.height * 0.8)
            glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            guard drifts, glow.animationKeys() == nil, bounds.width > 0 else { return }
            // As the mesh's center point drifted: across by 15%, up and down by 12%, out of step.
            for (key, by, duration) in [("position.x", bounds.width * 0.15, 12.5), ("position.y", bounds.height * 0.12, 9.7)] {
                let drift = CABasicAnimation(keyPath: key)
                drift.byValue = by
                drift.fromValue = (key == "position.x" ? bounds.midX : bounds.midY) - by / 2
                drift.duration = duration
                drift.autoreverses = true
                drift.repeatCount = .infinity
                drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(drift, forKey: key)
            }
        }
    }
}
