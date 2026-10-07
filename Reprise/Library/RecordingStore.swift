import AVFoundation
import AppKit

/// One recorded call. Lives in its own folder:
/// `~/Movies/Reprise/<id>/{recording.json, audio.m4a, screen.mov, transcript.txt}`
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

    var folder: URL { RecordingStore.root.appending(path: id, directoryHint: .isDirectory) }
    var finalAudioURL: URL { folder.appending(path: "audio.m4a") }
    var partialAudioURL: URL { folder.appending(path: "audio.aac") }
    /// Whichever audio file exists: the finished `.m4a`, or the in-progress stream.
    var audioURL: URL { FileManager.default.fileExists(atPath: partialAudioURL.path) ? partialAudioURL : finalAudioURL }
    var videoURL: URL { folder.appending(path: "screen.mov") }
    var transcriptURL: URL { folder.appending(path: "transcript.txt") }
    // ponytail: a call trashed in Finder keeps its clones' space until macOS clears the temporary
    // folder (3 days unused). Clear this folder for calls gone at reload if that's too late.
    /// The clones Share and dragging out hand over under the title. Trashing the call removes them.
    var copiesFolder: URL { FileManager.default.temporaryDirectory.appending(path: "reprise-calls/\(id)", directoryHint: .isDirectory) }
}

@Observable final class RecordingStore {
    /// `REPRISE_ROOT` points a development build at a scratch library.
    static let root = ProcessInfo.processInfo.environment["REPRISE_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? URL.moviesDirectory.appending(path: "Reprise", directoryHint: .isDirectory)

    private(set) var recordings: [Recording] = []
    /// Read once, not on every keystroke of a search. `nil` inside: there's no transcript.
    @ObservationIgnored private var transcripts: [Recording.ID: String?] = [:]

    init() { reload() }

    func reload() {
        transcripts.removeAll()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        recordings = folders
            .compactMap { folder in
                var recording = try? decoder.decode(Recording.self, from: Data(contentsOf: folder.appending(path: "recording.json")))
                recording?.id = folder.lastPathComponent // a folder copied or renamed in Finder is that folder, not the one it came from
                return recording
            }
            .sorted { $0.startedAt > $1.startedAt }
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
        return Recording(id: id, title: app.map { "\($0.name) call" } ?? "Recording", app: app, startedAt: date, duration: 0, hasVideo: false)
    }

    func transcript(of recording: Recording) -> String? {
        if let cached = transcripts[recording.id] { return cached }
        let text = try? String(contentsOf: recording.transcriptURL, encoding: .utf8)
        transcripts[recording.id] = text
        return text
    }

    func save(_ recording: Recording) {
        transcripts.removeValue(forKey: recording.id) // saved after a transcript is written
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard (try? encoder.encode(recording).write(to: recording.folder.appending(path: "recording.json"), options: .atomic)) != nil else { return }
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: recordings.firstIndex { $0.startedAt < recording.startedAt } ?? recordings.endIndex)
        }
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

    /// Moves the recording to the Trash, so it can be recovered. Returns where it is in the Trash.
    func delete(_ recording: Recording) -> URL? {
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: &trashed)) != nil else { return nil }
        try? FileManager.default.removeItem(at: recording.copiesFolder) // or they'd keep its space after the Trash is emptied
        recordings.removeAll { $0.id == recording.id }
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
