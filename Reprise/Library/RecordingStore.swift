import AVFoundation
import AppKit
import CoreSpotlight
import EventKit

/// One recorded call. Lives in its own folder:
/// `~/Movies/Reprise/<id>/{recording.json, audio.m4a, you.m4a or .wav, them.m4a or .wav, screen.mov, transcript.txt, transcript.json}`
/// While recording, audio goes to `audio.aac` (ADTS), which stays playable even if the app is
/// killed mid-call; it's repackaged into `audio.m4a` when the recording stops.
struct Recording: Codable, Identifiable, Equatable {
    var id: String // folder name, e.g. "2026-10-06 21.30.12 Zoom"
    var title: String
    var app: MeetingApp?
    let startedAt: Date
    var duration: TimeInterval
    var hasVideo: Bool
    /// Seconds into the audio where the screen recording starts. The movie, recorded without sound,
    /// gets all of the audio, and its picture from there.
    var movieStart: TimeInterval?
    /// Moments marked during the call, in seconds into the audio (and the movie, which has all of it).
    var marks: [TimeInterval]?
    /// Who else was invited to the calendar event the call belongs to.
    var participants: [String]?

    var folder: URL { RecordingStore.root.appending(path: id, directoryHint: .isDirectory) }
    var finalAudioURL: URL { folder.appending(path: "audio.m4a") }
    var partialAudioURL: URL { folder.appending(path: "audio.aac") }
    /// Whichever audio file exists: the finished `.m4a`, or the in-progress stream.
    var audioURL: URL { FileManager.default.fileExists(atPath: partialAudioURL.path) ? partialAudioURL : finalAudioURL }
    /// Each side on its own, when Settings ask for it: your microphone, then everyone else. As AAC,
    /// a crash-safe stream while recording, repackaged when it stops.
    var tracks: [(partial: URL, final: URL)] {
        ["you", "them"].map { (folder.appending(path: "\($0).aac"), folder.appending(path: "\($0).m4a")) }
    }
    /// The sides uncompressed, as WAV, whole as they're written.
    var losslessTracks: [URL] { ["you", "them"].map { folder.appending(path: "\($0).wav") } }
    /// The sides as saved, in whichever format; none for a call recorded without them.
    var sides: [URL]? {
        [losslessTracks, tracks.map(\.final)].first { $0.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
    }
    var videoURL: URL { folder.appending(path: "screen.mov") }
    var transcriptURL: URL { folder.appending(path: "transcript.txt") }
    /// The transcript phrase by phrase, with who said it and when: from separate tracks or a service that tells voices apart.
    var segmentsURL: URL { folder.appending(path: "transcript.json") }
    // ponytail: a call trashed in Finder keeps its clones' space until macOS clears the temporary
    // folder (3 days unused). Clear this folder for calls gone at reload if that's too late.
    /// The clones Share and dragging out hand over under the title. Trashing the call removes them.
    var copiesFolder: URL { Self.copies.appending(path: id, directoryHint: .isDirectory) }
    static let copies = FileManager.default.temporaryDirectory.appending(path: "reprise-calls", directoryHint: .isDirectory)
}

/// Names a call after the calendar event it belongs to, when Settings ask for it.
enum CalendarEvents {
    static let key = "calendarTitles"
    /// Made on first use: with the setting off, Reprise never talks to the calendar.
    private static let store = EKEventStore()

    static var isAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func requestAccess() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    static func event(at date: Date) -> EKEvent? {
        guard UserDefaults.standard.bool(forKey: key), isAllowed else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: date.addingTimeInterval(-12 * 3600), end: date + early, calendars: nil))
        return event(at: date, among: events)
    }

    /// Everyone invited but you and the rooms: by name, or by address when the invitation has no name.
    static func participants(of event: EKEvent) -> [String] {
        (event.attendees ?? [])
            .filter { !$0.isCurrentUser && ![.room, .resource].contains($0.participantType) }
            .compactMap { $0.name ?? $0.url.absoluteString.split(separator: "mailto:").last.map(String.init) }
    }

    /// A call joined a few minutes early belongs to the event about to start.
    private static let early: TimeInterval = 10 * 60

    /// The event going on at `date`, or about to start: the one whose start is nearest. Not all-day
    /// ones, and not those you declined.
    static func event(at date: Date, among events: [EKEvent]) -> EKEvent? {
        events
            .filter { !$0.isAllDay && $0.startDate <= date + early && $0.endDate > date && $0.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
    }
}

@Observable final class RecordingStore {
    /// The library: the folder chosen in Settings, or Movies › Reprise. Changes only with the
    /// choice, never under a recording. `REPRISE_ROOT` points a development build at a scratch library.
    private(set) static var root = chosenRoot()
    static let defaultRoot = URL.moviesDirectory.appending(path: "Reprise", directoryHint: .isDirectory)
    /// A bookmark, as Finder's aliases: the folder moved or renamed in Finder is still the library.
    private static let rootKey = "libraryFolder"

    // ponytail: a library on a disk that isn't there at launch falls back to the default folder
    // until the next launch with the disk. Watch for volumes mounting if that matters.
    private static func chosenRoot() -> URL {
        if let scratch = ProcessInfo.processInfo.environment["REPRISE_ROOT"] { return URL(filePath: scratch, directoryHint: .isDirectory) }
        guard let bookmark = UserDefaults.standard.data(forKey: rootKey), let (folder, isStale) = resolve(bookmark) else { return defaultRoot }
        if isStale, let fresh = try? folder.bookmarkData() { UserDefaults.standard.set(fresh, forKey: rootKey) }
        return folder
    }

    /// Where the bookmarked folder is now, if it's there. Stale: it moved, and the bookmark should say where to.
    static func resolve(_ bookmark: Data) -> (folder: URL, isStale: Bool)? {
        var isStale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return (folder, isStale)
    }

    /// Shows and saves the calls in `folder` from now on: the default folder for none. The calls
    /// recorded so far stay where they are.
    func useLibrary(at folder: URL?) {
        UserDefaults.standard.set(folder.flatMap { $0.path == Self.defaultRoot.path ? nil : try? $0.bookmarkData() }, forKey: Self.rootKey)
        Self.root = Self.chosenRoot()
        reload()
    }

    private(set) var recordings: [Recording] = []
    /// Read once, not on every keystroke of a search. `nil` inside: there's no transcript.
    @ObservationIgnored private var transcripts: [Recording.ID: String?] = [:]
    @ObservationIgnored private var segments: [Recording.ID: [Transcript.Segment]?] = [:]

    init() { reload() }

    func reload() {
        transcripts.removeAll()
        segments.removeAll()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Not hidden ones: a call being trimmed is put together in one.
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        recordings = folders
            .compactMap { folder in
                var recording = try? decoder.decode(Recording.self, from: Data(contentsOf: folder.appending(path: "recording.json")))
                recording?.id = folder.lastPathComponent // a folder copied or renamed in Finder is that folder, not the one it came from
                return recording
            }
            .sorted { $0.startedAt > $1.startedAt }
        updateSpotlight()
    }

    /// With its transcript read for it, not kept: Spotlight and Shortcuts ask in the background,
    /// and kept, the transcripts of every call they asked about stayed in memory.
    func entity(of recording: Recording) -> CallEntity {
        CallEntity(recording, transcript: transcripts[recording.id] ?? (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)))
    }

    // MARK: Spotlight

    /// Not the tests' library or a development build's scratch one: Spotlight is for the user's calls.
    private static let indexesSpotlight = !isTesting && ProcessInfo.processInfo.environment["REPRISE_ROOT"] == nil
    /// The calls Spotlight has, so a launch indexes only what changed while Reprise wasn't running.
    /// A new number indexes the whole library again, for a change in what's indexed.
    private static let indexedKey = "spotlightIndexed.1"

    /// Indexes the calls Spotlight doesn't have yet, and removes those gone from the library.
    private func updateSpotlight() {
        guard Self.indexesSpotlight else { return }
        let indexed = Set(UserDefaults.standard.stringArray(forKey: Self.indexedKey) ?? [])
        let new = recordings.filter { !indexed.contains($0.id) }
        let gone = indexed.subtracting(recordings.map(\.id))
        guard !new.isEmpty || !gone.isEmpty else { return }
        UserDefaults.standard.set(recordings.map(\.id), forKey: Self.indexedKey)
        let entities = new.map(entity)
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: Array(gone), ofType: CallEntity.self)
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }

    /// The call as it is now: renamed, marked, finished or transcribed.
    private func index(_ recording: Recording) {
        guard Self.indexesSpotlight else { return }
        let entity = entity(of: recording)
        Task { try? await CSSearchableIndex.default().indexAppEntities([entity]) }
        var indexed = UserDefaults.standard.stringArray(forKey: Self.indexedKey) ?? []
        if !indexed.contains(recording.id) { indexed.append(recording.id); UserDefaults.standard.set(indexed, forKey: Self.indexedKey) }
    }

    /// Creates the folder for a recording that is about to start.
    func create(app: MeetingApp?, at date: Date) throws -> Recording {
        let stamp = date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let name = "\(stamp) \((app?.name ?? "Recording").replacingOccurrences(of: "/", with: "-"))" // a "/" would nest folders
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        // Two recordings within one second get two folders: in one, each would write over the other's sound.
        var id = name
        for copy in 2... {
            do {
                try FileManager.default.createDirectory(at: Self.root.appending(path: id, directoryHint: .isDirectory), withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                id = "\(name) \(copy)"
            }
        }
        let event = CalendarEvents.event(at: date)
        let title = event?.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.map { String(localized: "\($0.name) call") } ?? String(localized: "Recording")
        let participants = event.map(CalendarEvents.participants)
        return Recording(id: id, title: title, app: app, startedAt: date, duration: 0, hasVideo: false,
                         participants: participants?.isEmpty == false ? participants : nil)
    }

    func transcript(of recording: Recording) -> String? {
        if let cached = transcripts[recording.id] { return cached }
        let text = try? String(contentsOf: recording.transcriptURL, encoding: .utf8)
        transcripts[recording.id] = text
        return text
    }

    func segments(of recording: Recording) -> [Transcript.Segment]? {
        if let cached = segments[recording.id] { return cached }
        let read = try? JSONDecoder().decode(Transcript.self, from: Data(contentsOf: recording.segmentsURL)).segments
        segments[recording.id] = read
        return read
    }

    /// The call as Markdown, for Copy with Details: what and when it was, the moments marked, who
    /// said what and when, and the folder, for an AI agent that can open the files.
    func brief(of recording: Recording) -> String {
        var lines = [
            "# \(recording.title)",
            "",
            [recording.app?.name ?? String(localized: "Recording"), recording.startedAt.formatted(date: .long, time: .shortened), recording.duration.clock].joined(separator: " · "),
            String(localized: "Files: `\(recording.folder.path)`"),
        ]
        if let participants = recording.participants {
            lines.append(String(localized: "Participants: \(participants.formatted(.list(type: .and)))"))
        }
        if let marks = recording.marks, !marks.isEmpty {
            lines.append(String(localized: "Marked moments: \(marks.map(\.clock).joined(separator: ", "))"))
        }
        lines += ["", "## \(String(localized: "Transcript"))", ""]
        if let segments = segments(of: recording) {
            lines += Transcript(segments: segments).turns.map { turn in
                "[\(turn.start.clock)] " + (Transcript.name(of: turn.speaker).map { "\($0): " } ?? "") + turn.text + "\n"
            }
        } else {
            lines.append(transcript(of: recording) ?? String(localized: "Not transcribed. The call's audio is in its folder."))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    func save(_ recording: Recording) {
        transcripts.removeValue(forKey: recording.id) // saved after a transcript is written
        segments.removeValue(forKey: recording.id)
        guard (try? Self.write(recording, into: recording.folder)) != nil else { return }
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: recordings.firstIndex { $0.startedAt < recording.startedAt } ?? recordings.endIndex)
        }
        index(recording)
    }

    private static func write(_ recording: Recording, into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: folder.appending(path: "recording.json"), options: .atomic)
    }

    // MARK: Parts of a call

    /// The part of the call within `range`, in seconds, as a file of its own under the title: the
    /// movie when there is one, else the sound. Cut without re-encoding.
    func clip(of recording: Recording, _ range: ClosedRange<TimeInterval>) async throws -> URL {
        let source = recording.hasVideo ? recording.videoURL : recording.audioURL
        let folder = recording.copiesFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // "Standup 12.30–13.45": a colon would show as a slash in Finder.
        let times = [range.lowerBound, range.upperBound].map { $0.clock.replacingOccurrences(of: ":", with: ".") }.joined(separator: "–")
        let clip = folder.appending(path: "\(recording.title.replacingOccurrences(of: "/", with: "-")) \(times).\(source.pathExtension)")
        try await Self.cut(source, to: range, into: clip)
        return clip
    }

    /// Cuts the call down to `range`: each of its files, its marks and its transcript. The call as
    /// it was goes to the Trash; returns where, for Undo.
    func trim(_ recording: Recording, to range: ClosedRange<TimeInterval>) async throws -> URL {
        let files = FileManager.default
        let trimmed = Self.root.appending(path: ".\(recording.id) trimmed", directoryHint: .isDirectory) // hidden from the library
        try? files.removeItem(at: trimmed)
        try files.createDirectory(at: trimmed, withIntermediateDirectories: false)
        var cut = recording
        do {
            for name in ["audio.m4a", "you.m4a", "them.m4a", "you.wav", "them.wav", "screen.mov"] {
                let file = recording.folder.appending(path: name)
                guard files.fileExists(atPath: file.path) else { continue }
                try await Self.cut(file, to: range, into: trimmed.appending(path: name))
            }
            cut.duration = range.upperBound - range.lowerBound
            cut.marks = recording.marks?.compactMap { range.contains($0) ? $0 - range.lowerBound : nil }
            cut.movieStart = recording.movieStart.map { max(0, $0 - range.lowerBound) }
            // The phrases within it, timed from its start. A transcript without times can't be cut:
            // it stays with the call as it was, and the cut one can be transcribed again.
            if let segments = segments(of: recording) {
                let time = { (seconds: TimeInterval) in (seconds * 1000).rounded() / 1000 } // to the millisecond, as the transcriber writes them
                let kept = segments.compactMap { segment -> Transcript.Segment? in
                    guard segment.end > range.lowerBound, segment.start < range.upperBound else { return nil }
                    var segment = segment
                    (segment.start, segment.end) = (time(max(0, segment.start - range.lowerBound)), time(min(segment.end, range.upperBound) - range.lowerBound))
                    return segment
                }
                try JSONEncoder().encode(Transcript(segments: kept)).write(to: trimmed.appending(path: "transcript.json"))
                try Transcript(segments: kept).text.write(to: trimmed.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
            }
            try Self.write(cut, into: trimmed)
        } catch {
            try? files.removeItem(at: trimmed)
            throw error
        }
        var trashed: NSURL?
        do { try files.trashItem(at: recording.folder, resultingItemURL: &trashed) } catch { // a server's folder has no Trash
            try? files.removeItem(at: trimmed)
            throw error
        }
        try files.moveItem(at: trimmed, to: recording.folder)
        try? files.removeItem(at: recording.copiesFolder) // clones of the files as they were
        save(cut)
        return trashed! as URL
    }

    nonisolated static func cut(_ source: URL, to range: ClosedRange<TimeInterval>, into destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        export.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 48_000),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 48_000))
        let type: AVFileType = switch destination.pathExtension {
        case "wav": .wav
        case "mov": .mov
        default: .m4a
        }
        try await export.export(to: destination, as: type)
    }

    /// Deletes the early capture of calls nobody chose to record (Reprise quit while it asked):
    /// a folder with an audio stream but no `recording.json`.
    func deleteUnanswered() {
        let files = FileManager.default
        for folder in (try? files.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        where !files.fileExists(atPath: folder.appending(path: "recording.json").path)
            && files.fileExists(atPath: folder.appending(path: "audio.aac").path) {
            try? files.removeItem(at: folder)
        }
    }

    /// Repackages the crash-safe ADTS stream into a regular `.m4a` (no re-encoding), gives the
    /// movie its sound, and saves.
    @discardableResult
    func finalize(_ recording: Recording) async -> Recording {
        var recording = recording
        // Before the mix's stream goes: while that's there, the next launch repairs the sides too.
        for track in recording.tracks where FileManager.default.fileExists(atPath: track.partial.path) {
            if (try? await Self.remux(track.partial, to: track.final)) != nil { try? FileManager.default.removeItem(at: track.partial) }
        }
        var remuxed = false
        if FileManager.default.fileExists(atPath: recording.partialAudioURL.path) {
            remuxed = (try? await Self.remux(recording.partialAudioURL, to: recording.finalAudioURL)) != nil
        }
        if recording.hasVideo {
            let sound = remuxed ? recording.finalAudioURL : recording.audioURL
            let merged = if let offset = recording.movieStart {
                (try? await Self.replaceSound(of: recording.videoURL, with: sound, from: offset)) != nil
            } else { false }
            // A movie that won't open, or one without the call's sound: the library plays the audio
            // instead of a silent movie. The movie stays in the folder.
            if !merged {
                log.error("The movie couldn't get the call's sound; the library plays the audio instead")
                recording.hasVideo = false
            }
        }
        // The stream goes last: a crash before this repeats the whole repair on the next launch.
        if remuxed { try? FileManager.default.removeItem(at: recording.partialAudioURL) }
        if recording.duration == 0, let seconds = try? await AVURLAsset(url: recording.audioURL).load(.duration).seconds {
            recording.duration = seconds // a recording cut short by a crash
        }
        recording.title = recordings.first { $0.id == recording.id }?.title ?? recording.title // renamed while saving
        save(recording)
        return recording
    }

    /// The sound of a call recorded elsewhere as `audio`: the file itself when it's an `.m4a`, else
    /// encoded into one, as the transcriber uploads it (a WAV's sound as it is would be ten times
    /// the size). A movie gives its sound.
    @concurrent static func importSound(of file: URL, to audio: URL) async throws {
        guard file.pathExtension.lowercased() != "m4a" else { return try FileManager.default.copyItem(at: file, to: audio) }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await export.export(to: audio, as: .m4a)
    }

    nonisolated private static func remux(_ source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: destination, as: .m4a)
    }

    /// Gives the movie all of `audio`'s sound, without re-encoding. Its picture starts `offset`
    /// seconds in, where the screen recording began, so the movie plays the call from its first second.
    nonisolated private static func replaceSound(of movie: URL, with audio: URL, from offset: TimeInterval) async throws {
        let video = AVURLAsset(url: movie), sound = AVURLAsset(url: audio)
        // Done already: a crash before the stream went repeats the save, and the picture would move again.
        guard try await video.loadTracks(withMediaType: .audio).isEmpty else { return }
        guard let picture = try await video.loadTracks(withMediaType: .video).first,
              let voice = try await sound.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let length = try await video.load(.duration), soundLength = try await sound.load(.duration)
        let start = CMTime(seconds: max(0, offset), preferredTimescale: 48_000) // the audio always starts first
        guard soundLength > start else { throw CocoaError(.fileReadCorruptFile) }
        let range = try await picture.load(.timeRange)

        let composition = AVMutableComposition()
        let screen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try screen?.insertTimeRange(range, of: picture, at: .zero)
        // Until the screen recording began, its first frame stays on rather than a black picture: the
        // library opens a call on its screen, and Finder still makes a thumbnail. Only that frame gets longer.
        let firstFrame = picture.makeSampleCursor(presentationTimeStamp: range.start).map { cursor in
            let shown = cursor.presentationTimeStamp
            return cursor.stepInPresentationOrder(byCount: 1) == 1 ? cursor.presentationTimeStamp - shown : range.duration
        }
        if let firstFrame {
            screen?.scaleTimeRange(CMTimeRange(start: .zero, duration: firstFrame), toDuration: firstFrame + start)
        } else { // black until then
            screen?.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: start))
        }
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: min(start + length, soundLength)), of: voice, at: .zero)

        let temporary = movie.deletingLastPathComponent().appending(path: "screen-call.mov")
        try? FileManager.default.removeItem(at: temporary)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: temporary, as: .mov)
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: temporary)
    }

    /// Settings' "Keep screen recordings": days, or none for forever.
    static let keepScreenKey = "keepScreenDays"

    /// Moves the screen recordings of calls older than Settings keep them to the Trash. The calls
    /// stay, with their sound: the movie takes most of a call's space.
    func trashOldScreens() {
        let days = UserDefaults.standard.integer(forKey: Self.keepScreenKey)
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        for var recording in recordings where recording.startedAt < cutoff && FileManager.default.fileExists(atPath: recording.videoURL.path) {
            guard (try? FileManager.default.trashItem(at: recording.videoURL, resultingItemURL: nil)) != nil else { continue }
            log.notice("Moved the screen recording of \(recording.id, privacy: .public) to the Trash")
            recording.hasVideo = false
            save(recording)
        }
    }

    /// The space the library takes on disk.
    @concurrent static func size(of folder: URL) async -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Moves the recording to the Trash, so it can be recovered. Returns where it is in the Trash.
    func delete(_ recording: Recording) -> URL? {
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: &trashed)) != nil else { return nil }
        try? FileManager.default.removeItem(at: recording.copiesFolder) // or they'd keep its space after the Trash is emptied
        recordings.removeAll { $0.id == recording.id }
        updateSpotlight()
        return trashed as URL?
    }

    func revealInFinder(_ recording: Recording? = nil) {
        if let recording {
            NSWorkspace.shared.activateFileViewerSelecting([recording.hasVideo ? recording.videoURL : recording.audioURL])
        } else {
            try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Self.root)
        }
    }
}
