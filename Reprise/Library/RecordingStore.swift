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

    var folder: URL { RecordingStore.root.appending(path: id, directoryHint: .isDirectory) }
    var finalAudioURL: URL { folder.appending(path: "audio.m4a") }
    var partialAudioURL: URL { folder.appending(path: "audio.aac") }
    /// Whichever audio file exists: the finished `.m4a`, or the in-progress stream.
    var audioURL: URL { FileManager.default.fileExists(atPath: partialAudioURL.path) ? partialAudioURL : finalAudioURL }
    var videoURL: URL { folder.appending(path: "screen.mov") }
    var transcriptURL: URL { folder.appending(path: "transcript.txt") }
    var transcript: String? { try? String(contentsOf: transcriptURL, encoding: .utf8) }
}

@Observable final class RecordingStore {
    /// `REPRISE_ROOT` points a development build at a scratch library.
    static let root = ProcessInfo.processInfo.environment["REPRISE_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? URL.moviesDirectory.appending(path: "Reprise", directoryHint: .isDirectory)

    private(set) var recordings: [Recording] = []

    init() { reload() }

    func reload() {
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
            id: "\(stamp) \(app?.name ?? "Recording")",
            title: app.map { "\($0.name) call" } ?? "Recording",
            app: app,
            startedAt: date,
            duration: 0,
            hasVideo: false
        )
        try FileManager.default.createDirectory(at: recording.folder, withIntermediateDirectories: true)
        return recording
    }

    func save(_ recording: Recording) {
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

    /// Repackages the crash-safe ADTS stream into a regular `.m4a` (no re-encoding) and saves.
    @discardableResult
    func finalize(_ recording: Recording) async -> Recording {
        var recording = recording
        if FileManager.default.fileExists(atPath: recording.partialAudioURL.path),
           (try? await Self.remux(recording.partialAudioURL, to: recording.finalAudioURL)) != nil {
            try? FileManager.default.removeItem(at: recording.partialAudioURL)
        }
        if recording.duration == 0, let seconds = try? await AVURLAsset(url: recording.audioURL).load(.duration).seconds {
            recording.duration = seconds // a recording cut short by a crash
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

    /// Moves the recording to the Trash, so it can be recovered.
    func delete(_ recording: Recording) {
        try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
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
