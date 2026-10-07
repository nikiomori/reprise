import AVFoundation
import OSLog
import SwiftUI

let log = Logger(subsystem: "dev.nikiomori.reprise", category: "app")

/// Unit tests run inside the app.
let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

/// What the floating island at the top of the screen is showing.
enum IslandState: Equatable {
    case hidden
    case prompt(MeetingApp)
    case recording
    case saved(Recording)
    case problem(String)
}

/// The app's brain: listens for calls, runs recordings, owns the library.
@Observable final class AppModel {
    static let shared = AppModel()

    let store = RecordingStore()
    let detector = MeetingDetector()
    private(set) var island = IslandState.hidden {
        // The prompt went away without a Record: nobody wanted that early audio.
        didSet { if let app = preroll?.recording.app, island != .prompt(app) { discardPreroll() } }
    }
    private(set) var session: Session?
    /// The call captured from its first second while the prompt asks whether to keep it.
    private(set) var preroll: Session?
    /// The floating pill is tucked away for the rest of this recording.
    private(set) var pillHidden = false
    private(set) var transcribing: [Recording.ID: Double] = [:]
    private(set) var transcriptionErrors: [Recording.ID: String] = [:]
    var selection: Recording.ID?

    var recordScreen = UserDefaults.standard.bool(forKey: "recordScreen") {
        didSet { UserDefaults.standard.set(recordScreen, forKey: "recordScreen") }
    }

    struct Session {
        var recording: Recording
        let audio: AudioRecorder
        let screen: ScreenRecorder?
    }

    private init() {
        detector.onStart = { [unowned self] app in callStarted(app) }
        detector.onEnd = { [unowned self] app in callEnded(app) }
        guard !isTesting else { return } // no calls and no repairs: the tests drive the pieces themselves
        detector.start()
        store.deleteUnanswered()
        // Finish recordings that were cut short last time (crash, force quit, power loss).
        Task {
            for recording in store.recordings where FileManager.default.fileExists(atPath: recording.partialAudioURL.path) {
                await store.finalize(recording)
            }
        }
    }

    // MARK: Calls

    private func callStarted(_ app: MeetingApp) {
        log.notice("Call started in \(app.id, privacy: .public), rule: \(app.rule.rawValue, privacy: .public)")
        guard session == nil else { return }
        switch app.rule {
        case .always: Task { await startRecording(app: app) }
        case .ask:
            show(.prompt(app), for: .seconds(Self.promptSeconds))
            if UserDefaults.standard.bool(forKey: "recordFromStart") { startPreroll(app) }
        case .never: break
        }
    }

    private func callEnded(_ app: MeetingApp) {
        log.notice("Call ended in \(app.id, privacy: .public)")
        if session?.recording.app == app {
            Task { await stopRecording() }
        } else if island == .prompt(app) {
            show(.hidden)
        }
    }

    // MARK: Recording

    static let promptSeconds: TimeInterval = 20

    @ObservationIgnored private var starting = false
    @ObservationIgnored private var prerolling: Task<Void, Never>?

    func startRecording(app: MeetingApp?) async {
        await prerolling?.value // Record was pressed while the early capture was still starting
        guard session == nil, !starting else { return } // a double-click must not start two recorders
        starting = true
        defer { starting = false }
        do {
            var recording: Recording
            let audio: AudioRecorder
            if let kept = takePreroll(for: app) {
                (recording, audio) = (kept.recording, kept.audio)
            } else {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    return show(.problem("Reprise needs microphone access"), for: .seconds(6))
                }
                recording = try store.create(app: app, at: .now)
                audio = AudioRecorder(url: recording.partialAudioURL, processes: tapped(app))
                // Off the main thread: the first start blocks while macOS shows its permission prompt.
                try await Task.detached { try audio.start() }.value
            }

            // Keep the audio going without the screen; a call is more important than its picture.
            var screen: ScreenRecorder?
            var screenProblem: String?
            if recordScreen {
                if ScreenRecorder.hasPermission {
                    let recorder = ScreenRecorder()
                    recorder.onStop = { [weak self] error in // macOS ended it mid-call: the movie would freeze unnoticed
                        let message = error.localizedDescription
                        Task { @MainActor in
                            log.error("The screen recording stopped: \(message, privacy: .public)")
                            self?.show(.problem("Recording without the screen: \(message)"), for: .seconds(8))
                        }
                    }
                    do {
                        try await recorder.start(url: recording.videoURL, showing: app)
                        screen = recorder
                        recording.hasVideo = true
                    } catch {
                        try? FileManager.default.removeItem(at: recording.videoURL) // what the failed start left
                        screenProblem = "Recording without the screen: \(error.localizedDescription)"
                    }
                } else {
                    UserDefaults.standard.set(true, forKey: "screenAccessRequested") // Settings offers the relaunch
                    CGRequestScreenCaptureAccess()
                    screenProblem = "Recording without the screen. Allow Screen Recording, then relaunch Reprise."
                }
            }
            session = Session(recording: recording, audio: audio, screen: screen)
            log.notice("Recording started: \(recording.id, privacy: .public), screen: \(screen != nil)")
            store.save(recording) // visible in the library right away, even if Reprise quits mid-call
            pillHidden = !UserDefaults.standard.bool(forKey: "showRecordingPill")
            pillHidden ? show(.recording, for: .seconds(2)) : show(.recording)
            if let screenProblem { show(.problem(screenProblem), for: .seconds(8)) }
            Task { await watch(recording.id, audio) }
            if let app, !detector.active.contains(app) { await stopRecording() } // the call ended while starting
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            show(.problem(error.localizedDescription), for: .seconds(6))
        }
    }

    // ponytail: notices a lost microphone within 10 s; listen to the device list if that's too late.
    /// Keeps the sound coming: a recording that stopped getting it, usually because the microphone
    /// went away (it also carries the clock for the Mac's sound), goes on with the one there is now.
    /// Warns once when that doesn't help (a full disk), no sound comes at all, or a call goes on
    /// without the other side (both usually a missing permission).
    private func watch(_ id: Recording.ID, _ audio: AudioRecorder) async {
        var written = -1
        var shown: String? // each warning once while it lasts, so another one still gets through
        var stalledBefore = false
        for tick in 0... {
            // The first look comes early: until the movie's start is saved, a crash leaves it without sound.
            try? await Task.sleep(for: .seconds(tick == 0 ? 1 : 5))
            guard let session, session.recording.id == id else { return }
            // Saved once known, so a movie cut short by a crash still gets its sound.
            if session.recording.movieStart == nil, let start = Self.movieStart(in: session) {
                self.session?.recording.movieStart = start
                store.save(self.session!.recording)
            }
            let now = audio.framesWritten
            let stalled = tick > 0 && now == written
            let problem = tick == 0 ? nil
                : !audio.hasHeardSound ? "No sound is coming in. Check Privacy & Security."
                : stalled && stalledBefore ? "The recording stopped getting sound. Check the microphone and the free disk space."
                // Three minutes in: a waiting room is silent too.
                : tick >= 36 && session.recording.app != nil && !audio.hasHeardThem ? "No sound from the other side yet. Check System Audio Recording in Privacy & Security."
                : nil
            if let problem, problem != shown { show(.problem(problem), for: .seconds(8)) }
            shown = problem
            if stalled {
                log.notice("The recording stopped getting sound; restarting it on the current microphone")
                do { try await Task.detached { try audio.restart() }.value } catch {
                    log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            stalledBefore = stalled
            written = now
        }
    }

    /// The call app's processes when Settings limit the audio to it. None, the whole Mac: a
    /// recording without a call, or an app whose audio processes aren't there.
    private func tapped(_ app: MeetingApp?) -> [AudioObjectID] {
        guard let app, UserDefaults.standard.bool(forKey: "callAppAudioOnly") else { return [] }
        return MeetingDetector.processes(of: app)
    }

    /// Starts capturing as the prompt shows, so Record keeps the call from its first second.
    private func startPreroll(_ app: MeetingApp) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        prerolling = Task {
            guard let recording = try? store.create(app: app, at: .now) else { return }
            let audio = AudioRecorder(url: recording.partialAudioURL, processes: tapped(app))
            guard (try? await Task.detached { try audio.start() }.value) != nil else {
                try? FileManager.default.removeItem(at: recording.folder)
                return
            }
            let early = Session(recording: recording, audio: audio, screen: nil)
            // Dismissed, the call ended, or another call took the prompt while starting.
            guard island == .prompt(app) else { return discard(early) }
            discardPreroll() // never drop a running capture without stopping it
            preroll = early
        }
    }

    /// The early capture of this call, if there is one. An early capture of any other call is dropped.
    private func takePreroll(for app: MeetingApp?) -> Session? {
        guard let preroll, app != nil, preroll.recording.app == app else {
            discardPreroll()
            return nil
        }
        self.preroll = nil
        return preroll
    }

    private func discardPreroll() {
        guard let preroll else { return }
        self.preroll = nil
        discard(preroll)
    }

    /// Deletes it for good, not to the Trash: it was never a recording anyone asked for.
    private func discard(_ early: Session) {
        let (audio, folder) = (early.audio, early.recording.folder)
        Task.detached { // see finish(_:)
            audio.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        log.notice("Discarded the early capture of an unanswered prompt")
    }

    /// Quitting while the prompt asks: the early capture goes now, not on the next launch.
    func discardPrerollBeforeQuit() {
        guard let preroll else { return }
        self.preroll = nil
        preroll.audio.stop()
        try? FileManager.default.removeItem(at: preroll.recording.folder)
    }

    /// The stop in progress, so quitting can wait until the files are written.
    @ObservationIgnored private(set) var stopping: Task<Void, Never>?

    func stopRecording() async {
        guard let session else {
            await stopping?.value
            return
        }
        self.session = nil
        let task = Task { await finish(session) }
        stopping = task
        await task.value
        if stopping == task { stopping = nil }
    }

    private func finish(_ session: Session) async {
        let audio = session.audio
        // Off the main thread: when Reprise is the last one on a Bluetooth mic, stopping waits for
        // the headphones to leave their call mode, which can take seconds.
        await Task.detached { audio.stop() }.value
        if audio.hasHeardThem { UserDefaults.standard.set(true, forKey: "systemAudioHeard") } // Settings shows it as allowed
        await session.screen?.stop()
        var recording = session.recording
        recording.duration = Date.now.timeIntervalSince(recording.startedAt)
        recording.movieStart = recording.movieStart ?? Self.movieStart(in: session)
        recording = await store.finalize(recording)
        log.notice("Recording saved: \(recording.id, privacy: .public), \(Int(recording.duration))s")
        switch island {
        case .prompt: break // the next call's prompt still waits for an answer
        default: show(.saved(recording), for: .seconds(5))
        }
        if UserDefaults.standard.bool(forKey: TranscriptionSettings.autoKey), TranscriptionSettings.service != nil {
            transcribe(recording)
        }
    }

    /// Seconds into the audio where the movie starts.
    private static func movieStart(in session: Session) -> TimeInterval? {
        guard let audio = session.audio.startHostTime, let movie = session.screen?.startHostTime else { return nil }
        return (Double(AudioConvertHostTimeToNanos(movie)) - Double(AudioConvertHostTimeToNanos(audio))) / 1e9
    }

    /// Records the call Reprise is asking about, or the one going on; otherwise a recording without a call.
    func record() async {
        if case .prompt(let app) = island { await startRecording(app: app) } else { await startRecording(app: detector.active.first) }
    }

    func toggleRecording() {
        Task { session == nil ? await record() : await stopRecording() }
    }

    func dismissPrompt() { show(.hidden) }

    func hidePill() {
        pillHidden = true
        show(.hidden)
    }

    func showPill() {
        pillHidden = false
        if session != nil { show(.recording) }
    }

    #if DEBUG
    func debugShow(_ state: IslandState) { island = state }
    #endif

    /// Each side's level for the pill's two dots, 0...1.
    func voices() -> (you: Float, them: Float) {
        #if DEBUG
        if session == nil, DebugSnapshots.isRunning { return (.random(in: 0...0.2), .random(in: 0.02...0.45)) }
        #endif
        return session?.audio.readVoices() ?? (0, 0)
    }

    // MARK: Island

    @ObservationIgnored private var islandTimeout: Task<Void, Never>?

    private func show(_ state: IslandState, for duration: Duration? = nil) {
        islandTimeout?.cancel()
        island = state
        // The panel never takes focus, so VoiceOver wouldn't notice it.
        let spoken: String? = switch state {
        case .prompt(let app): "\(app.name): Record this call?"
        case .problem(let message): message
        default: nil
        }
        if let spoken {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        guard let duration else { return }
        islandTimeout = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { island = session == nil || pillHidden ? .hidden : .recording }
        }
    }

    // MARK: Library

    func rename(_ recording: Recording, to title: String) {
        var recording = recording
        recording.title = title
        store.save(recording)
        if session?.recording.id == recording.id { session?.recording.title = title }
    }

    func isLive(_ recording: Recording) -> Bool { session?.recording.id == recording.id }

    func delete(_ recording: Recording, undo: UndoManager?) {
        guard !isLive(recording) else { return } // stop first; otherwise capture continues into the Trash
        let index = store.recordings.firstIndex { $0.id == recording.id } ?? 0
        guard let trashed = store.delete(recording) else { return }
        // The next call takes its place, as in Mail and Voice Memos.
        if selection == recording.id {
            selection = (store.recordings.dropFirst(index).first ?? store.recordings.last)?.id
        }
        // Edit > Undo puts it back, as in Finder and Mail.
        undo?.registerUndo(withTarget: self) { model in
            guard (try? FileManager.default.moveItem(at: trashed, to: recording.folder)) != nil else { return }
            model.store.reload()
            model.selection = recording.id
        }
        undo?.setActionName("Move to Trash")
    }

    func transcribe(_ recording: Recording) {
        guard !isLive(recording), transcribing[recording.id] == nil, let service = TranscriptionSettings.service else { return }
        transcribing[recording.id] = 0
        transcriptionErrors[recording.id] = nil
        let apiKey = TranscriptionSettings.apiKey
        let language = UserDefaults.standard.string(forKey: TranscriptionSettings.languageKey)
        Task {
            do {
                let text = try await Transcriber.transcribe(recording.audioURL, service: service, apiKey: apiKey, language: language) { value in
                    await MainActor.run { self.transcribing[recording.id] = value }
                }
                try text.write(to: recording.transcriptURL, atomically: true, encoding: .utf8)
            } catch {
                transcriptionErrors[recording.id] = error.localizedDescription
            }
            transcribing[recording.id] = nil
            store.save(store.recordings.first { $0.id == recording.id } ?? recording) // nudge observers
        }
    }
}

/// An error that is only its message.
nonisolated struct Failure: LocalizedError {
    let errorDescription: String?
}
