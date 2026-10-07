import AVFoundation
import AppKit

/// One recorded call. Lives in its own folder:
/// `~/Movies/Reprise/<id>/{recording.json, audio.m4a, screen.mov, transcript.txt}`
/// While recording, audio goes to `audio.aac` (ADTS), which stays playable even if the app is
/// killed mid-call; it's repackaged into `audio.m4a` when the recording stops.
struct Recording: Codable, Identifiable, Hashable {
    let id: String // folder name, e.g. "2026-10-06 21.30.12 Zoom"
    var title: String
    var app: MeetingApp?
    let startedAt: Date
    var duration: TimeInterval
    var hasVideo: Bool
    /// Seconds into the audio where the movie starts. The movie, recorded without sound, gets the audio from there.
    var movieStart: TimeInterval?

    var folder: URL { RecordingStore.root.appending(path: id, directoryHint: .isDirectory) }
    var finalAudioURL: URL { folder.appending(path: "audio.m4a") }
    var partialAudioURL: URL { folder.appending(path: "audio.aac") }
    /// Whichever audio file exists: the finished `.m4a`, or the in-progress stream.
    var audioURL: URL { FileManager.default.fileExists(atPath: partialAudioURL.path) ? partialAudioURL : finalAudioURL }
    var videoURL: URL { folder.appending(path: "screen.mov") }
    var transcriptURL: URL { folder.appending(path: "transcript.txt") }
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
            .compactMap { try? decoder.decode(Recording.self, from: Data(contentsOf: $0.appending(path: "recording.json"))) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Creates the folder for a recording that is about to start.
    func create(app: MeetingApp?, at date: Date) throws -> Recording {
        let stamp = date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let recording = Recording(
            id: "\(stamp) \((app?.name ?? "Recording").replacingOccurrences(of: "/", with: "-"))", // a "/" would nest folders
            title: app.map { "\($0.name) call" } ?? "Recording",
            app: app,
            startedAt: date,
            duration: 0,
            hasVideo: false
        )
        try FileManager.default.createDirectory(at: recording.folder, withIntermediateDirectories: true)
        return recording
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
        if FileManager.default.fileExists(atPath: recording.partialAudioURL.path),
           (try? await Self.remux(recording.partialAudioURL, to: recording.finalAudioURL)) != nil {
            try? FileManager.default.removeItem(at: recording.partialAudioURL)
        }
        if recording.hasVideo, let offset = recording.movieStart,
           (try? await Self.replaceSound(of: recording.videoURL, with: recording.finalAudioURL, from: offset)) == nil {
            log.error("The movie has no sound: the call's sound couldn't be added")
        }
        if recording.duration == 0, let seconds = try? await AVURLAsset(url: recording.audioURL).load(.duration).seconds {
            recording.duration = seconds // a recording cut short by a crash
        }
        // A screen recording that failed, or was cut short before its movie was finished:
        // play the audio instead of a movie that won't open.
        if recording.hasVideo, !((try? await AVURLAsset(url: recording.videoURL).load(.isPlayable)) ?? false) {
            recording.hasVideo = false
        }
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

    /// Gives the movie the sound of `audio` from `offset` seconds on, without re-encoding.
    nonisolated private static func replaceSound(of movie: URL, with audio: URL, from offset: TimeInterval) async throws {
        let video = AVURLAsset(url: movie), sound = AVURLAsset(url: audio)
        guard let picture = try await video.loadTracks(withMediaType: .video).first,
              let voice = try await sound.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let length = try await video.load(.duration)
        let start = CMTime(seconds: max(0, offset), preferredTimescale: 48_000) // the audio always starts first
        let available = try await sound.load(.duration) - start
        guard available > .zero else { throw CocoaError(.fileReadCorruptFile) }

        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(try await picture.load(.timeRange), of: picture, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: start, duration: min(length, available)), of: voice, at: .zero)

        let temporary = movie.deletingLastPathComponent().appending(path: "screen-call.mov")
        try? FileManager.default.removeItem(at: temporary)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: temporary, as: .mov)
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: temporary)
    }

    /// Moves the recording to the Trash, so it can be recovered.
    func delete(_ recording: Recording) {
        guard (try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)) != nil else { return }
        recordings.removeAll { $0.id == recording.id }
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
