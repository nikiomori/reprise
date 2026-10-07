import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reprise").font(.headline)
                Spacer()
                Status(model: model)
            }

            RecordButton(model: model)

            if model.session != nil, model.pillHidden {
                Button("Show the Floating Pill", systemImage: "capsule.on.rectangle", action: model.showPill)
                    .buttonStyle(.rowHighlight)
            }

            Toggle(isOn: $model.recordScreen) {
                Text("Also record the screen").frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            let recent = model.store.recordings.prefix(3)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    ForEach(recent) { recording in
                        Button {
                            open(recording)
                        } label: {
                            RecentRow(recording: recording)
                        }
                        .buttonStyle(.rowHighlight)
                    }
                }
            }

            Divider()

            HStack(spacing: 4) {
                Button("Library") { open(nil) }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.rowHighlight)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func open(_ recording: Recording?) {
        if let recording { model.selection = recording.id }
        openWindow(id: "library")
        NSApp.activate()
    }
}

private struct Status: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.session != nil {
                Label("Recording", systemImage: "circle.fill").foregroundStyle(.red)
            } else if let app = model.detector.active.first {
                Label("\(app.name) call", systemImage: "phone.fill").foregroundStyle(.green)
            } else {
                Label("Waiting for calls", systemImage: "ear").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .labelStyle(StatusLabelStyle())
        .contentTransition(.opacity)
        .animation(.smooth, value: model.session == nil)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

private struct RecordButton: View {
    let model: AppModel

    var body: some View {
        Button(action: model.toggleRecording) {
            HStack(spacing: 10) {
                if let session = model.session {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                    Spacer()
                    LevelMeter(level: model.level)
                    ElapsedTime(since: session.recording.startedAt)
                } else {
                    Image(systemName: "record.circle.fill")
                    Text("Start Recording")
                    Spacer()
                }
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CapsuleButtonStyle(color: model.session == nil ? .red : Color(white: 0.35),
                                        padding: EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)))
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.session == nil)
    }
}

private struct RecentRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: recording.app, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(recording.title).lineLimit(1)
                Text("\(recording.startedAt.formatted(.relative(presentation: .named))) · \(recording.duration.clock)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if recording.hasVideo {
                Image(systemName: "display").font(.caption).foregroundStyle(.tertiary).help("Includes a screen recording")
            }
        }
    }
}

/// Menu-like rows: flat until hovered.
struct RowHighlightButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == RowHighlightButtonStyle {
    static var rowHighlight: RowHighlightButtonStyle { .init() }
}
