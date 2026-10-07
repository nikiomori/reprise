import AVKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.recordings) { recording in
                            RecordingRow(recording: recording, isLive: model.session?.recording.id == recording.id)
                                .tag(recording.id)
                                .contextMenu {
                                    ShareLink("Share…", item: recording.hasVideo ? recording.videoURL : recording.audioURL)
                                    Button("Show in Finder") { model.store.revealInFinder(recording) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { model.delete(recording) }
                                        .disabled(model.isLive(recording))
                                }
                        }
                    }
                }
            }
            .focused($listFocused)
            .defaultFocus($listFocused, true) // not the title field, which would select itself
            .searchable(text: $search, placement: .sidebar, prompt: "Search calls")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .onDeleteCommand { if let selected { model.delete(selected) } }
            .overlay {
                if !model.store.recordings.isEmpty, sections.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let selected {
                RecordingDetail(recording: selected, model: model)
                    .id("\(selected.id) \(selected.duration)") // duration is set when the file is finalized
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Calls Yet", systemImage: "waveform")
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                } description: {
                    Text("Join a call, and Reprise offers to record it.")
                }
            } else {
                ContentUnavailableView("No Call Selected", systemImage: "waveform", description: Text("Select a call to play it."))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.selection)
        .navigationSubtitle(Text("^[\(model.store.recordings.count) call](inflect: true)"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.toggleRecording) {
                    Label(model.session == nil ? "Record" : "Stop", systemImage: model.session == nil ? "record.circle" : "stop.circle.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(.red)
                .help(model.session == nil ? "Start recording now" : "Stop recording")
            }
        }
        .onAppear {
            if model.selection == nil { model.selection = model.store.recordings.first?.id }
            DispatchQueue.main.async { listFocused = true } // arrows browse calls right away
        }
    }

    private var selected: Recording? {
        model.store.recordings.first { $0.id == model.selection }
    }

    private var sections: [(title: String, recordings: [Recording])] {
        let calendar = Calendar.current
        let matches = model.store.recordings.filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || (model.store.transcript(of: $0)?.localizedStandardContains(search) ?? false)
        }
        let grouped = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : calendar.isDate(day, equalTo: .now, toGranularity: .year) ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            return (title, grouped[day]!)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: recording.app, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).lineLimit(1)
                Group {
                    if isLive {
                        Text("\(recording.startedAt, format: .dateTime.hour().minute()) · \(Text("Recording").foregroundStyle(.red))")
                    } else {
                        Text("\(recording.startedAt, format: .dateTime.hour().minute()) · \(recording.duration.clock)")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if recording.hasVideo {
                Image(systemName: "display").font(.caption).foregroundStyle(.tertiary).help("Includes a screen recording")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct RecordingDetail: View {
    let recording: Recording
    let model: AppModel
    @State private var player: Player
    @State private var title: String
    @State private var renaming = false
    @FocusState private var titleFocused: Bool

    init(recording: Recording, model: AppModel) {
        self.recording = recording
        self.model = model
        _player = State(initialValue: Player(url: recording.hasVideo ? recording.videoURL : recording.audioURL))
        _title = State(initialValue: recording.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.isLive(recording) {
                    LiveCard(model: model, since: recording.startedAt)
                } else {
                    if recording.hasVideo {
                        VideoPlayer(player: player.avPlayer)
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
                    }
                    PlayerCard(player: player, waveformSource: recording.audioURL)
                        .tint(.primary)
                    TranscriptSection(recording: recording, model: model)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarSpacer(.fixed) // this call's actions apart from Record, which isn't about it
            ToolbarItemGroup {
                ShareLink(item: recording.hasVideo ? recording.videoURL : recording.audioURL)
                Button("Show in Finder", systemImage: "folder") { model.store.revealInFinder(recording) }
                // No confirmation, like Finder: the Trash is the undo.
                Button("Move to Trash", systemImage: "trash") { model.delete(recording) }
                    .disabled(model.isLive(recording))
            }
        }
        .onDisappear { player.avPlayer.pause() }
    }

    private func saveTitle() {
        renaming = false
        if title.isEmpty { title = recording.title }
        if title != recording.title { model.rename(recording, to: title) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIcon(app: recording.app, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                // Plain text until clicked, so opening a recording never selects (and risks typing over) its title.
                if renaming {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(.title, weight: .bold))
                        .focused($titleFocused)
                        .onAppear { titleFocused = true }
                        .onSubmit(saveTitle)
                        .onChange(of: titleFocused) { if !titleFocused { saveTitle() } }
                        .onExitCommand { title = recording.title; renaming = false }
                } else {
                    Text(title)
                        .font(.system(.title, weight: .bold))
                        .onTapGesture { renaming = true }
                        .pointerStyle(.horizontalText) // reads as editable, like a name in Finder
                        .help("Click to rename")
                }
                Text([recording.app?.name ?? "Recording", recording.startedAt.formatted(date: .long, time: .shortened), model.isLive(recording) ? nil : recording.duration.clock].compactMap(\.self).joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A call still being recorded has nothing to play yet.
private struct LiveCard: View {
    let model: AppModel
    let since: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording").font(.headline)
                Text("You can play the call after it ends.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            ElapsedTime(since: since).font(.title3.weight(.semibold))
            Button("Stop", systemImage: "stop.fill") { Task { await model.stopRecording() } }
                .buttonStyle(.glass)
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

// MARK: - Player

@Observable final class Player {
    let avPlayer: AVPlayer
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1 {
        didSet {
            avPlayer.defaultRate = rate // the video's own play button uses it too
            if isPlaying { avPlayer.rate = rate }
        }
    }
    @ObservationIgnored private var observers: [Any] = []

    init(url: URL) {
        avPlayer = AVPlayer(url: url)
        // Also called when playback starts or stops — at the end, or from the video's own controls.
        observers.append(avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                if self.isPlaying != (self.avPlayer.rate != 0) { self.isPlaying.toggle() }
            }
        })
        Task { duration = (try? await avPlayer.currentItem?.asset.load(.duration).seconds) ?? 0 }
    }

    func toggle() {
        isPlaying.toggle()
        if isPlaying, duration > 0, time >= duration - 0.1 { seek(to: 0) } // played to the end: from the top
        isPlaying ? avPlayer.playImmediately(atRate: rate) : avPlayer.pause()
    }

    func seek(to seconds: Double) {
        time = seconds
        avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) { seek(to: min(max(0, time + seconds), duration)) }
}

private struct PlayerCard: View {
    let player: Player
    let waveformSource: URL

    var body: some View {
        VStack(spacing: 10) {
            WaveformScrubber(player: player, source: waveformSource)
                .frame(height: 64)
            // Elapsed and remaining under the wave, like Music and Voice Memos.
            HStack {
                Text(player.time.clock)
                Spacer()
                Text("−\(max(0, player.duration - player.time).clock)")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(-15) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .help("Back 15 seconds")
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button("Forward 15 Seconds", systemImage: "goforward.15") { player.skip(15) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .help("Forward 15 seconds")
            }
            // The speed rides on the side so play stays in the true center.
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Menu {
                    Picker("Speed", selection: Bindable(player).rate) {
                        ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(player.rate.formatted())×").monospacedDigit()
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .fixedSize()
                .help("Playback speed")
            }
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

private struct WaveformScrubber: View {
    let player: Player
    let source: URL
    @State private var peaks: [Float] = []
    @State private var hover: CGFloat?
    private let bars = 120

    var body: some View {
        GeometryReader { geometry in
            let progress = player.duration > 0 ? player.time / player.duration : 0
            let wave = WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0, count: bars) : peaks, grown: peaks.isEmpty ? 0 : 1)
            // The playhead only moves a mask; the bars themselves are drawn once.
            ZStack {
                wave.fill(.tertiary)
                wave.fill(.tint).mask(alignment: .leading) {
                    Rectangle().frame(width: geometry.size.width * progress)
                }
            }
            .animation(.easeOut(duration: 0.8), value: peaks.isEmpty)
            .overlay(alignment: .leading) {
                if let hover {
                    Rectangle().fill(.primary.opacity(0.35)).frame(width: 1).offset(x: hover)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active(let point) = phase { hover = point.x } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                player.seek(to: player.duration * min(max(0, value.location.x / geometry.size.width), 1))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(player.time.clock) of \(player.duration.clock)")
        .accessibilityAdjustableAction { direction in
            player.skip(direction == .increment ? 15 : -15)
        }
        .task { peaks = await Waveform.peaks(of: source, count: bars) }
    }
}

/// All the bars as one shape: one path, one layer, however fast the playhead moves.
nonisolated private struct WaveformShape: Shape {
    let peaks: [Float]
    /// 0 → 1 as the bars rise, each a little after the one to its left.
    var grown: Double

    var animatableData: Double {
        get { grown }
        set { grown = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let gap: CGFloat = 2
        let count = CGFloat(max(1, peaks.count))
        let width = (rect.width - gap * (count - 1)) / count
        var path = Path()
        for (i, peak) in peaks.enumerated() {
            let rise = min(1, max(0, grown * 1.5 - Double(i) / count * 0.5))
            let height = max(3, rect.height * CGFloat(peak) * rise)
            path.addRoundedRect(
                in: CGRect(x: CGFloat(i) * (width + gap), y: rect.midY - height / 2, width: width, height: height),
                cornerSize: CGSize(width: width / 2, height: width / 2)
            )
        }
        return path
    }
}

nonisolated enum Waveform {
    /// Loudness envelope of an audio file, normalized to 0...1. Decoding an hour of audio takes
    /// 0.7 s of CPU, so the result waits next to the file, hidden, for the next time.
    @concurrent static func peaks(of url: URL, count: Int) async -> [Float] {
        let saved = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).waveform")
        if let data = try? Data(contentsOf: saved), data.count == count * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let perBucket = AVAudioFrameCount(max(1, file.length / Int64(count)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: perBucket) else { return [] }
        var peaks: [Float] = []
        while peaks.count < count, (try? file.read(into: buffer, frameCount: perBucket)) != nil, buffer.frameLength > 0 {
            guard !Task.isCancelled else { return [] } // the next call was selected before this one's wave was done
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            peaks.append(rms)
        }
        peaks += Array(repeating: 0, count: count - peaks.count)
        let loudest = peaks.max() ?? 0
        if loudest > 0 { peaks = peaks.map { ($0 / loudest).squareRoot() } }
        try? peaks.withUnsafeBytes { Data($0) }.write(to: saved)
        return peaks
    }
}

// MARK: - Transcript

private struct TranscriptSection: View {
    let recording: Recording
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript").font(.title3.bold())
                Spacer()
                if let text = model.store.transcript(of: recording) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.glass)
                }
            }

            Group {
                if let progress = model.transcribing[recording.id] {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcribing…").shimmering()
                        ProgressView(value: progress).progressViewStyle(.linear)
                    }
                } else if let text = model.store.transcript(of: recording) {
                    Text(text)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if TranscriptionSettings.service != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.transcriptionErrors[recording.id] {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .foregroundStyle(.secondary)
                        }
                        Button("Transcribe", systemImage: "text.bubble") { model.transcribe(recording) }
                            .buttonStyle(.glassProminent)
                            .disabled(model.isLive(recording))
                    }
                } else {
                    HStack {
                        Text("Connect a transcription service to turn calls into text.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        SettingsLink { Text("Set Up…") }.buttonStyle(.glass)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
            .animation(.smooth, value: model.transcribing[recording.id] == nil)
        }
    }
}

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .overlay {
                LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                    .scaleEffect(x: 0.6)
                    .offset(x: phase * 160)
                    .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
