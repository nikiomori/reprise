import SwiftUI

/// Laid out like the system's own menu bar modules (Wi‑Fi, Focus): round chips that fill
/// with color when on, section headers, full-width rows.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reprise")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)

            RecordRow(model: model)
            Toggle("Record the Screen", isOn: $model.recordScreen)
                .toggleStyle(ChipToggleStyle(icon: "rectangle.inset.filled.badge.record"))
            if model.session != nil, model.pillHidden {
                Button(action: model.showPill) {
                    HStack(spacing: 10) {
                        Chip(icon: "capsule")
                        Text("Show the Floating Pill")
                    }
                }
            }

            let recent = model.store.recordings.prefix(3)
            if !recent.isEmpty {
                MenuDivider()
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                ForEach(recent) { recording in
                    Button { open(recording) } label: { RecentRow(recording: recording) }
                }
            }

            MenuDivider()
            Button("Open Library") { open(nil) }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Reprise") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.rowHighlight)
        .padding(5)
        .frame(width: 300)
    }

    private func open(_ recording: Recording?) {
        if let recording { model.selection = recording.id }
        openWindow(id: "library")
        NSApp.activate()
    }
}

private struct RecordRow: View {
    let model: AppModel

    var body: some View {
        Button(action: model.toggleRecording) {
            HStack(spacing: 10) {
                Chip(icon: model.session == nil ? "record.circle" : "stop.fill", tint: model.session == nil ? nil : .red)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.session == nil ? "Start Recording" : "Stop Recording")
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let session = model.session {
                    ElapsedTime(since: session.recording.startedAt).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.smooth, value: model.session == nil)
    }

    private var status: String {
        if let session = model.session { return session.recording.app.map { "\($0.name) call" } ?? "Without a call" }
        if let app = model.detector.active.first { return "Call in \(app.name)" }
        return "Waiting for calls"
    }
}

/// The round icon of Control Center rows: gray when off, filled with color when on.
private struct Chip: View {
    let icon: String
    var tint: Color?

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .frame(width: 26, height: 26)
            .background(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary), in: .circle)
    }
}

private struct ChipToggleStyle: ToggleStyle {
    let icon: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Chip(icon: icon, tint: configuration.isOn ? .accentColor : nil)
                configuration.label
            }
        }
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .animation(.smooth(duration: 0.2), value: configuration.isOn)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
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
