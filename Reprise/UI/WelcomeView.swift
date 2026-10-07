import AVFoundation
import ServiceManagement
import SwiftUI

struct WelcomeView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var audioGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
                Text("Reprise").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Be present. Reprise remembers.").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            VStack(spacing: 4) {
                Step(icon: "mic.fill", tint: .red, title: "Microphone and system audio",
                     detail: "So both sides of the call end up in the recording.", done: audioGranted) {
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
                HStack(spacing: 14) {
                    StepIcon(icon: "power", tint: .green)
                    Toggle("Open Reprise at login", isOn: $launchAtLogin).toggleStyle(.switch)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            Button {
                finish()
            } label: {
                Text("Get Started").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .padding(24)
        }
        .frame(width: 520)
        .onAppear { withAnimation(.spring(duration: 0.8).delay(0.15)) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = ScreenRecorder.hasPermission
        }
    }

    private func requestAudio() async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return }
        // A blink of a recording makes macOS ask for system-audio access now rather than mid-call.
        let probe = AudioRecorder(url: FileManager.default.temporaryDirectory.appending(path: "reprise-probe.m4a"))
        await Task.detached {
            try? probe.start()
            try? await Task.sleep(for: .milliseconds(600))
            probe.stop()
        }.value
        withAnimation(.spring) { audioGranted = true }
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
    let title: String
    let detail: String
    let done: Bool
    var actionTitle = "Allow"
    let action: () async -> Void

    var body: some View {
        HStack(spacing: 14) {
            StepIcon(icon: icon, tint: tint)
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

private struct StepIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: .rect(cornerRadius: 9))
    }
}

/// A tiny desktop that plays the whole story on loop: call → record → saved.
private struct Demo: View {
    @State private var stage = 0

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = Float(context.date.timeIntervalSinceReferenceDate * 0.25)
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.15 * sin(t), 0.5 + 0.12 * cos(t * 1.3)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: [
                    .indigo, .purple, .pink,
                    .blue, .orange.mix(with: .pink, by: 0.4), .red,
                    .teal, .indigo, .purple,
                ])
            }
            Rectangle().fill(.black.opacity(0.18)).frame(height: 22)

            capsule
                .padding(.top, 30)
                .animation(.spring(duration: 0.55, bounce: 0.3), value: stage)
        }
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
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
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("0:12").font(.callout.weight(.semibold)).monospacedDigit()
                        LevelMeter { Float.random(in: 0.05...0.6) }.scaleEffect(0.8)
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
            .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
        }
    }
}
