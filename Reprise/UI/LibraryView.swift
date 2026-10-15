import AVKit
import Accelerate
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var dropping = false
    @State private var favoritesOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let sections = self.sections
        let shown = sections.flatMap(\.recordings)
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.recordings) { recording in
                            RecordingRow(recording: recording, isLive: model.isLive(recording), isSaving: model.saving.contains(recording.id))
                                .tag(recording.id)
                        }
                    }
                }
            }
            // One menu for the list, made on a right click: a menu on each row is a view graph kept for
            // every call, the window closed or not.
            .contextMenu(forSelectionType: Recording.ID.self) { ids in
                if let recording = shown.first(where: { ids.contains($0.id) }) {
                    ShareLink("Share…", item: CallFile(recording), preview: SharePreview(recording.title))
                        .disabled(model.isLive(recording)) // its file is still being written
                    Button("Show in Finder") { model.store.revealInFinder(recording) }
                    Button(recording.favorite == true ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(recording) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.delete(recording, shown: shown, undo: undoManager) }
                        .disabled(model.isLive(recording))
                }
            }
            .focused($listFocused)
            .defaultFocus($listFocused, true) // not the title field, which would select itself
            .searchable(text: $search, placement: .sidebar, prompt: "Search calls")
            .searchFocused($searchFocused)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .onDeleteCommand { if let selected { model.delete(selected, shown: shown, undo: undoManager) } }
            .overlay {
                if !model.store.recordings.isEmpty, sections.isEmpty {
                    if search.isEmpty { // only Favorites shown, and there are none
                        ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Calls you add to Favorites appear here."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .toolbar {
                // As Mail filters a mailbox, and together with the search.
                Toggle("Show Only Favorites", systemImage: "line.3.horizontal.decrease", isOn: $favoritesOnly)
                    .help("Show only favorites")
            }
            // A recording made elsewhere, dropped from Finder, becomes a call of its own.
            .dropDestination(for: URL.self) { files, _ in model.add(files) }
            .onDropSessionUpdated { dropping = $0.localSession == nil && [.entering, .active].contains($0.phase) } // not a call dragged out
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
                }
            }
        } detail: {
            if let selected {
                RecordingDetail(recording: selected, shown: shown, model: model, search: search)
                    .id("\(selected.id) \(selected.duration)") // duration is set when the file is finalized
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else if model.store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Calls Yet", systemImage: "waveform")
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
                }
                .tint(.red)
                .help(model.session == nil ? "Start recording now" : "Stop recording")
            }
        }
        .onAppear {
            if model.selection == nil { model.selection = model.store.recordings.first?.id }
            DispatchQueue.main.async { listFocused = true } // arrows browse calls right away
        }
        .onDisappear { model.store.forgetTranscripts() } // read for the search and the calls opened; the window's gone
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.store.reload() // calls removed or added in Finder meanwhile
        }
        .onReceive(NotificationCenter.default.publisher(for: .findCalls)) { _ in searchFocused = true }
    }

    private var selected: Recording? {
        model.store.recordings.first { $0.id == model.selection }
    }

    /// "Tuesday, October 6", capitalized as a heading in languages that write weekdays in lowercase.
    private static let dayTitle = {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.capitalizationContext = .beginningOfSentence
        return style
    }()

    private var sections: [(title: String, recordings: [Recording])] {
        let calendar = Calendar.current
        let matches = model.store.recordings.filter {
            (!favoritesOnly || $0.favorite == true) && (search.isEmpty || $0.title.localizedStandardContains(search)
                || ($0.participants ?? []).contains { $0.localizedStandardContains(search) }
                || (model.store.transcript(of: $0)?.localizedStandardContains(search) ?? false))
        }
        let grouped = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? String(localized: "Today")
                : calendar.isDateInYesterday(day) ? String(localized: "Yesterday")
                : calendar.isDate(day, equalTo: .now, toGranularity: .year) ? day.formatted(Self.dayTitle)
                : day.formatted(Self.dayTitle.year())
            return (title, grouped[day]!)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isLive: Bool
    let isSaving: Bool

    var body: some View {
        // Into Mail, Finder or another app, as from Finder; not while it's still being written.
        if isLive { row } else { row.draggable(CallFile(recording)) }
    }

    private var row: some View {
        HStack(spacing: 10) {
            AppIcon(app: recording.app, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).lineLimit(1)
                Group {
                    if isLive {
                        Text("\(recording.startedAt, format: .dateTime.hour().minute()) · \(isSaving ? Text("Saving…") : Text("Recording").foregroundStyle(.red))")
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
                Image(systemName: "display").font(.caption).foregroundStyle(.tertiary)
                    .help("Includes a screen recording")
                    .accessibilityLabel("Includes a screen recording") // not "display"
            }
            if recording.favorite == true {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A call's file under the call's title, for Share and dragging out: Mail and the Desktop get
/// "Zoom call.m4a", not one "audio.m4a" after another. Still handed over as a file, as from
/// Finder, not as a file promise (`FileRepresentation`), which not every app takes.
nonisolated struct CallFile: Transferable {
    let url: URL
    let title: String
    let copies: URL

    @MainActor init(_ recording: Recording) {
        url = recording.hasVideo ? recording.videoURL : recording.audioURL
        title = recording.title
        copies = recording.copiesFolder
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.named() }
    }

    /// A clone under the title: instant, and it takes no space while the call is kept. Made on the
    /// main thread at each right-click, drag and Share, so where the file can't be cloned (a library
    /// on another disk) it goes under its own name rather than as a full copy each time. Each clone
    /// gets a folder of its own: a drag asks for several at once, and the file may have changed since.
    func named() -> URL {
        let folder = copies.appending(path: UUID().uuidString)
        let copy = folder.appending(path: "\(title.replacingOccurrences(of: "/", with: "-")).\(url.pathExtension)") // a "/" would nest folders
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              clonefile(url.path, copy.path, 0) == 0 else {
            try? FileManager.default.removeItem(at: folder)
            return url
        }
        return copy
    }
}

// MARK: - Detail

private struct RecordingDetail: View {
    let recording: Recording
    let shown: [Recording] // the library's list, to select the next call after Move to Trash
    let model: AppModel
    /// What the library is searched for: found in the transcript, and played from there.
    let search: String
    /// Made on appear, not in `init`: SwiftUI makes this view anew on every change around it
    /// (each letter typed into the search), and each would open the file in a new player.
    @State private var player: Player?
    @State private var title = "" // only while renaming; the header shows the saved title
    @State private var renaming = false
    @FocusState private var titleFocused: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if model.isLive(recording) {
                        LiveCard(model: model, recording: recording)
                    } else {
                        if let player {
                            if recording.hasVideo {
                                VideoPlayer(player: player.avPlayer)
                                    .aspectRatio(16 / 10, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 16))
                                    .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
                            }
                            PlayerCard(player: player, recording: recording, model: model)
                                .tint(.primary)
                        }
                        TranscriptSection(recording: recording, model: model, player: player, search: search)
                    }
                }
                .padding(32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .task(id: search) {
                if player == nil, !model.isLive(recording) {
                    player = Player(url: recording.hasVideo ? recording.videoURL : recording.audioURL)
                }
                find(scroller)
            }
        }
        .toolbar {
            ToolbarSpacer(.fixed) // this call's actions apart from Record, which isn't about it
            ToolbarItemGroup {
                let favorite = recording.favorite == true
                Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.fill" : "star") { model.toggleFavorite(recording) }
                    .keyboardShortcut("d") // as a page is added to favorites in a browser
                ShareLink(item: CallFile(recording), preview: SharePreview(recording.title))
                    .disabled(model.isLive(recording))
                Button("Show in Finder", systemImage: "folder") { model.store.revealInFinder(recording) }
                // No confirmation, like Finder: Edit > Undo puts it back.
                Button("Move to Trash", systemImage: "trash") { model.delete(recording, shown: shown, undo: undoManager) }
                    .disabled(model.isLive(recording))
            }
        }
        .onDisappear { player?.pause() }
    }

    /// The first phrase the search found, in sight and ready to play, as Find goes to the first match.
    private func find(_ scroller: ScrollViewProxy) {
        guard !search.isEmpty, let transcript = model.store.phrases(of: recording),
              let first = transcript.segments.firstIndex(where: { $0.text.localizedStandardContains(search) }),
              let paragraph = transcript.paragraphs.firstIndex(where: { $0.contains(first) }) else { return }
        if player?.isPlaying == false { player?.seek(to: transcript.segments[first].start) } // not away from what's playing
        withAnimation(reduceMotion ? nil : .smooth) { scroller.scrollTo(paragraph, anchor: .center) }
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
                        .onDisappear { if renaming { saveTitle() } } // another call clicked: kept, as in Finder
                        .onExitCommand { title = recording.title; renaming = false }
                } else {
                    Button { title = recording.title; renaming = true } label: { // a button, so the keyboard and VoiceOver reach it too
                        Text(recording.title).font(.system(.title, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.horizontalText) // reads as editable, like a name in Finder
                    .help("Click to rename")
                }
                Text([recording.app?.name ?? String(localized: "Recording"), recording.startedAt.formatted(date: .long, time: .shortened), model.isLive(recording) ? nil : recording.duration.clock].compactMap(\.self).joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let participants = recording.participants {
                    let everyone = participants.formatted(.list(type: .and))
                    Label(everyone, systemImage: "person.2")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(everyone)
                        .accessibilityLabel(String(localized: "Participants: \(everyone)"))
                }
            }
        }
    }
}

/// A call still being recorded, or saved after the stop, has nothing to play yet.
private struct LiveCard: View {
    let model: AppModel
    let recording: Recording

    var body: some View {
        let saving = model.saving.contains(recording.id)
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(saving ? "Saving…" : "Recording").font(.headline)
                Text(saving ? "You can play the call in a moment." : "You can play the call after it ends.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !saving {
                ElapsedTime(since: recording.startedAt).font(.title3.weight(.semibold))
                Button("Stop", systemImage: "stop.fill") { Task { await model.stopRecording() } }
                    .buttonStyle(.glass)
            }
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

// MARK: - Player

@Observable final class Player {
    private let url: URL
    /// Made at the first play, or by a movie, which shows its picture at once. Made for each call
    /// looked at, AVFoundation's playback took 2-3 MB, kept while the library stayed open, and after.
    @ObservationIgnored private var made: AVPlayer?
    /// Only the wave's played part reads it, as often as it changes.
    private(set) var time: Double = 0 {
        didSet {
            let whole = time.isFinite ? Int(time) : 0 // a seek into an unknown length
            if whole != second { second = whole }
            follow()
        }
    }
    /// `time` in whole seconds, for the clocks, which then redraw once a second.
    private(set) var second = 0
    /// When each phrase of the transcript begins, for it to show the one being played.
    @ObservationIgnored var cues: [Double] = [] { didSet { follow() } }
    /// The phrase being played: the last one begun. None until the call is played or a phrase clicked,
    /// and it changes only from one phrase to the next, so the transcript redraws only then.
    private(set) var cue: Int?
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1 {
        didSet {
            made?.defaultRate = rate // the video's own play button uses it too
            if isPlaying { made?.rate = rate }
        }
    }
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        loading = Task { duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }
    }

    var avPlayer: AVPlayer {
        if let made { return made }
        let player = AVPlayer(url: url)
        player.defaultRate = rate
        if time > 0 { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        made = player
        Task { [loading] in
            await loading?.value
            // As often as the playhead moves a pixel on a wave about 1400 wide, from 32 times a second to
            // once, and a fraction of a second, so the clocks still turn on the second. A 40-minute call
            // redrew the player 30 times a second: 6% CPU to play it.
            let intervals: [Double] = [1, 1 / 2, 1 / 4, 1 / 8, 1 / 16]
            let interval = intervals.first { $0 <= duration / 1400 } ?? 1 / 32
            // Also called when playback starts or stops — at the end, or from the video's own controls.
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.time = time.seconds
                    if self.isPlaying != (player.rate != 0) { self.isPlaying.toggle() }
                }
            }
        }
        return player
    }

    /// AVPlayer: an observer released without being removed is undefined behavior.
    isolated deinit {
        if let observer { made?.removeTimeObserver(observer) }
    }

    func toggle() {
        isPlaying.toggle()
        if isPlaying, duration > 0, time >= duration - 0.1 { seek(to: 0) } // played to the end: from the top
        isPlaying ? avPlayer.playImmediately(atRate: rate) : avPlayer.pause()
    }

    func pause() { made?.pause() }

    /// Before the first play, only where it'll start.
    func seek(to seconds: Double) {
        time = seconds
        made?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) { seek(to: min(max(0, time + seconds), duration)) }

    private func follow() {
        let current = time > 0 ? cues.lastIndex { $0 <= time } : nil
        if current != cue { cue = current }
    }
}

private struct PlayerCard: View {
    let player: Player
    let recording: Recording
    let model: AppModel
    /// The part being trimmed or shared, while it is.
    @State private var part: ClosedRange<TimeInterval>?
    @Environment(\.undoManager) private var undoManager

    private var marks: [TimeInterval] { recording.marks ?? [] }

    var body: some View {
        VStack(spacing: 10) {
            if !marks.isEmpty, player.duration > 0 {
                Marks(marks: marks, player: player)
            }
            WaveformScrubber(player: player, source: recording.audioURL)
                .frame(height: 64)
                .overlay {
                    // Not `Binding($part)`: Cancel crashed it, the frame being drawn once more after
                    // `part` was gone and its force-unwrapping binding read nil.
                    if let shown = part {
                        PartFrame(part: Binding { part ?? shown } set: { part = $0 }, duration: player.duration, marks: marks)
                    }
                }
            if let part {
                partBar(part)
            } else {
                controls
            }
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }

    /// While a part is chosen: play it, let it go, share it, or cut the call down to it.
    private func partBar(_ part: ClosedRange<TimeInterval>) -> some View {
        HStack(spacing: 10) {
            Button {
                if !player.isPlaying, !part.contains(player.time) { player.seek(to: part.lowerBound) }
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16, height: 16)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button("Cancel") { self.part = nil }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text(verbatim: "\(part.lowerBound.clock) – \(part.upperBound.clock)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("From \(part.lowerBound.clock) to \(part.upperBound.clock)")
            Spacer()
            ShareLink(item: Clip(isMovie: recording.hasVideo) { [model, recording] in try await model.store.clip(of: recording, part) },
                      preview: SharePreview(recording.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glass)
            .help("Share this part as a file of its own")
            Button("Trim") {
                player.pause()
                Task { await model.trim(recording, to: part, undo: undoManager) }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.transcribing[recording.id] != nil) // the transcript is being written
            .help("Keep only this part of the call. Edit › Undo puts the rest back.")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Elapsed and remaining under the wave, like Music and Voice Memos.
            HStack {
                Text(Double(player.second).clock)
                Spacer()
                Text("−\(max(0, player.duration - Double(player.second)).clock)")
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
            // Trimming and the speed ride on the sides so play stays in the true center.
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Button("Trim or Share a Part", systemImage: "scissors") { part = 0...player.duration }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .keyboardShortcut("t") // as in QuickTime Player
                    .disabled(player.duration <= 1)
                    .help("Trim or share a part")
            }
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
    }
}

/// The part being trimmed or shared, framed in yellow as QuickTime Player frames it, the rest
/// dimmed. Its edges are dragged, and stick to a flag they come near.
private struct PartFrame: View {
    @Binding var part: ClosedRange<TimeInterval>
    let duration: TimeInterval
    let marks: [TimeInterval]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let start = x(part.lowerBound, width), end = x(part.upperBound, width)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.background.opacity(0.65)).frame(width: start)
                Rectangle().fill(.background.opacity(0.65)).frame(width: max(0, width - end)).offset(x: end)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: max(6, end - start))
                    .offset(x: start)
            }
            .allowsHitTesting(false) // a click inside still plays from there
            edge(at: start, width: width, isStart: true)
            edge(at: end, width: width, isStart: false)
        }
        .coordinateSpace(.named("part"))
    }

    private func x(_ time: TimeInterval, _ width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func edge(at position: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        let time = isStart ? part.lowerBound : part.upperBound
        return Capsule()
            .fill(.yellow)
            .frame(width: 8)
            .padding(.vertical, -4)
            .contentShape(.rect.inset(by: -6))
            .position(x: min(max(position, 4), width - 4), y: 32)
            .frame(height: 64)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(coordinateSpace: .named("part")).onChanged { drag in
                move(isStart, to: duration * min(max(0, drag.location.x / width), 1), snapping: 6 / width * duration)
            })
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Start of the part" : "End of the part")
            .accessibilityValue(time.clock)
            .accessibilityAdjustableAction { direction in move(isStart, to: time + (direction == .increment ? 1 : -1), snapping: 0) }
    }

    /// At least a second long; near a flag, on it.
    private func move(_ isStart: Bool, to time: TimeInterval, snapping: TimeInterval) {
        let time = marks.first { abs($0 - time) <= snapping } ?? time
        part = isStart ? max(0, min(time, part.upperBound - 1))...part.upperBound : part.lowerBound...min(duration, max(time, part.lowerBound + 1))
    }
}

/// A part of a call for Share: cut as it's shared, not before. The movie when the call has one.
nonisolated struct Clip: Transferable {
    let isMovie: Bool
    let cut: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .quickTimeMovie) { SentTransferredFile(try await $0.cut()) }
            .exportingCondition(\.isMovie)
        FileRepresentation(exportedContentType: .mpeg4Audio) { SentTransferredFile(try await $0.cut()) }
            .exportingCondition { !$0.isMovie }
    }
}

private struct WaveformScrubber: View {
    let player: Player
    let source: URL
    @State private var peaks: [Float] = []
    @State private var hover: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bars = 120

    var body: some View {
        GeometryReader { geometry in
            let wave = WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0, count: bars) : peaks, grown: peaks.isEmpty ? 0 : 1)
            // The playhead only moves a mask; the bars themselves are drawn once.
            ZStack {
                wave.fill(.tertiary)
                wave.fill(.tint).mask(alignment: .leading) {
                    PlayedPart(player: player)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: peaks.isEmpty)
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
        .accessibilityValue("\(Double(player.second).clock) of \(player.duration.clock)")
        .accessibilityAdjustableAction { direction in
            player.skip(direction == .increment ? 15 : -15)
        }
        .task { peaks = await Waveform.peaks(of: source, count: bars) }
    }
}

/// Flags over the wave where moments were marked during the call. Each plays from a few seconds
/// before its moment: the button is pressed after what's worth finding has begun.
private struct Marks: View {
    let marks: [TimeInterval]
    let player: Player

    var body: some View {
        GeometryReader { geometry in
            ForEach(marks, id: \.self) { mark in
                Button { player.seek(to: max(0, mark - 5)) } label: {
                    Image(systemName: "flag.fill").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(mark.clock)
                .accessibilityLabel("Marker at \(mark.clock)")
                .position(x: geometry.size.width * min(1, mark / player.duration), y: geometry.size.height / 2)
            }
        }
        .frame(height: 14)
    }
}

/// The mask over the played bars: the one view that follows every move of the playhead. Scaled,
/// so the moves need no layout.
private struct PlayedPart: View {
    let player: Player

    var body: some View {
        Rectangle().scaleEffect(x: player.duration > 0 ? player.time / player.duration : 0, y: 1, anchor: .leading)
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
        let perBucket = max(1, Int(file.length) / count)
        // A bar read a second at a time: read whole, a bar of an hour and a half's call was 8.6 MB.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(perBucket, 1 << 16))) else { return [] }
        var peaks: [Float] = []
        var energy: Float = 0, frames = 0 // of the bar being read
        while peaks.count < count, (try? file.read(into: buffer, frameCount: AVAudioFrameCount(min(perBucket - frames, Int(buffer.frameCapacity))))) != nil, buffer.frameLength > 0 {
            guard !Task.isCancelled else { return [] } // the next call was selected before this one's wave was done
            energy += vDSP.sumOfSquares(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            frames += Int(buffer.frameLength)
            if frames == perBucket { peaks.append((energy / Float(frames)).squareRoot()); (energy, frames) = (0, 0) }
        }
        if frames > 0, peaks.count < count { peaks.append((energy / Float(frames)).squareRoot()) } // the end, short of a bar
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
    let player: Player?
    let search: String
    @State private var copied = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript").font(.title3.bold())
                Spacer()
                if let text = model.store.transcript(of: recording) {
                    // After a better service or model; the old text stays until the new one is written.
                    if TranscriptionSettings.service != nil, model.transcribing[recording.id] == nil {
                        Button("Transcribe Again", systemImage: "arrow.clockwise") { model.transcribe(recording) }
                            .buttonStyle(.glass)
                    }
                    // With details: the title and date, when each turn began, the marks, and the folder.
                    Menu {
                        Button("Copy with Details") { copy(model.store.brief(of: recording)) }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    } primaryAction: {
                        copy(text)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let error = model.transcriptionErrors[recording.id] { // over the old text, if it was a second try
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.secondary)
                }
                if let progress = model.transcribing[recording.id] {
                    ProgressView("Transcribing…", value: progress)
                } else if let transcript = model.store.phrases(of: recording) {
                    Phrases(transcript: transcript, participants: recording.participants ?? [], player: player, search: search) {
                        model.store.rename(voice: $0, to: $1, in: recording)
                    }
                } else if let text = model.store.transcript(of: recording) {
                    Paragraphs(text: text, search: search)
                } else if TranscriptionSettings.service != nil {
                    Button("Transcribe", systemImage: "text.bubble") { model.transcribe(recording) }
                        .buttonStyle(.glassProminent)
                        .disabled(model.isLive(recording))
                } else {
                    HStack {
                        Text("Connect a transcription service to turn calls into text.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Up…") { // on the Transcription tab, not the last one used
                            UserDefaults.standard.set(SettingsTab.transcription.rawValue, forKey: SettingsTab.key)
                            openSettings()
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
            .animation(.smooth, value: model.transcribing[recording.id] == nil)
        }
    }

    /// Says so on the button for a moment: copying shows nothing else.
    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// `transcript.json`: who said what, a paragraph each time the speaker changes, each phrase a click
/// away like the flags over the wave. A voice is named from the menu on its name.
private struct Phrases: View {
    let transcript: Transcript
    /// Who was invited, offered as the voices' names.
    let participants: [String]
    let player: Player?
    let search: String
    let rename: (_ speaker: String, _ name: String?) -> Void
    @State private var renaming: String? // the voice being named
    @State private var name = ""

    var body: some View {
        let segments = transcript.segments
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(transcript.paragraphs.enumerated()), id: \.offset) { index, phrases in
                let first = segments[phrases.lowerBound]
                if phrases.lowerBound == 0 || segments[phrases.lowerBound - 1].speaker != first.speaker, let speaker = first.speaker {
                    header(speaker, from: first.start)
                        .padding(.top, index == 0 ? 0 : 14)
                }
                Paragraph(segments: segments[phrases], color: Self.color(of: first.speaker), player: player, search: search)
                    .id(index) // where the search scrolls to
            }
        }
        .environment(\.openURL, OpenURLAction { url in // a phrase is a link to its time
            if url.scheme == "seek", let time = Double(url.absoluteString.dropFirst("seek:".count)) { player?.seek(to: time) }
            return .handled
        })
        .onChange(of: player == nil, initial: true) { player?.cues = segments.map(\.start) } // made after the transcript is shown
        .alert(Text("Rename “\(renaming.flatMap(transcript.name(of:)) ?? "")”"), isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }, presenting: renaming) { speaker in
            TextField("Name", text: $name)
            Button("Rename") { rename(speaker, name) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The voice's dot, its name with the menu to name it, and when it begins to speak.
    private func header(_ speaker: String, from start: Double) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Self.color(of: speaker)).frame(width: 8, height: 8)
            Menu {
                Picker("Name", selection: Binding { transcript.names?[speaker] } set: { rename(speaker, $0) }) {
                    Text(Transcript.label(of: speaker) ?? speaker).tag(String?.none)
                    ForEach(speaker == "you" ? [] : participants, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                Button("Rename…") { name = transcript.names?[speaker] ?? ""; renaming = speaker }
            } label: {
                Text(transcript.name(of: speaker) ?? speaker).font(.headline)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Click to rename")
            Spacer()
            Button(start.clock) { player?.seek(to: start) }
                .buttonStyle(.plain)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// You in gray; the others in red, as the logo's dot, then a color each.
    private static func color(of speaker: String?) -> Color {
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .teal, .pink, .brown]
        return switch speaker {
        case "you", nil: .gray
        case "them": .red
        case let number?: colors[max(0, (Int(number) ?? 1) - 1) % colors.count]
        }
    }
}

/// A paragraph's phrases as one text to read and select, each a link to its time: those played
/// dimmed, the one playing marked in its voice's color. The only part that follows the playhead.
private struct Paragraph: View {
    let segments: ArraySlice<Transcript.Segment>
    let color: Color
    let player: Player?
    let search: String

    var body: some View {
        let cue = player?.cue
        var text = AttributedString()
        for (i, segment) in zip(segments.indices, segments) {
            if i > segments.startIndex { text += AttributedString(" ") }
            var phrase = AttributedString(segment.text, marking: search)
            phrase.link = URL(string: "seek:\(segment.start)")
            if let cue, i <= cue { // not over what the search marked
                phrase.mergeAttributes(i == cue ? AttributeContainer().backgroundColor(color.opacity(0.2)) : AttributeContainer().foregroundColor(Color.secondary),
                                       mergePolicy: .keepCurrent)
            }
            text += phrase
        }
        return Text(text)
            .tint(.primary) // links read as text
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `transcript.txt` without the phrases' times, laid out a piece at a time as it scrolls into sight.
/// As one Text, an hour of it took 45 MB and 3 G instructions to lay out, kept after the window closed.
struct Paragraphs: View {
    let text: String
    let search: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.pieces(of: text).enumerated()), id: \.offset) { _, piece in
                Text(AttributedString(piece, marking: search))
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Its paragraphs, and a long one cut once it's past 1,000 characters: a service that gives only
    /// text gives the whole call as one.
    static func pieces(of text: String) -> [String] {
        text.components(separatedBy: "\n\n").flatMap { $0.utf8.count > 1000 ? cut($0, after: .bySentences) : [$0] }
    }

    /// After a sentence, or after a word in a sentence that goes on and on (speech recognized without
    /// punctuation).
    private static func cut(_ text: String, after unit: String.EnumerationOptions) -> [String] {
        var pieces: [String] = [], piece = ""
        text.enumerateSubstrings(in: text.startIndex..., options: [unit, .substringNotRequired]) { _, _, range, _ in
            let part = String(text[range])
            if unit == .bySentences, part.utf8.count > 1000 {
                if !piece.isEmpty { pieces.append(piece); piece = "" }
                pieces += cut(part, after: .byWords)
            } else {
                piece += part
                if piece.utf8.count >= 1000 { pieces.append(piece); piece = "" }
            }
        }
        return piece.isEmpty ? pieces : pieces + [piece]
    }
}

extension AttributedString {
    /// The text with what the search found marked, in the color Find marks it with in a document.
    init(_ text: String, marking search: String) {
        self.init(text)
        guard !search.isEmpty else { return }
        var rest = text.startIndex..<text.endIndex
        while let found = text[rest].localizedStandardRange(of: search) {
            if let range = Range(found, in: self) {
                self[range].backgroundColor = Color(nsColor: .findHighlightColor)
                self[range].foregroundColor = .black // on yellow in dark mode too
            }
            rest = found.upperBound..<text.endIndex
        }
    }
}
