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
    /// A moment of the call was marked, this many seconds in.
    case marked(TimeInterval)
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
    /// Recordings stopped but not saved yet: their files are still being finished.
    private(set) var saving: Set<Recording.ID> = []
    /// The call captured from its first second while the prompt asks whether to keep it.
    private(set) var preroll: Session?
    /// The floating pill is tucked away for the rest of this recording.
    private(set) var pillHidden = false
    private(set) var transcribing: [Recording.ID: Double] = [:]
    private(set) var transcriptionErrors: [Recording.ID: String] = [:]
    var selection: Recording.ID?

    var recordScreen = UserDefaults.standard.bool(forKey: "recordScreen") {
        didSet {
            UserDefaults.standard.set(recordScreen, forKey: "recordScreen")
            // Asked as it's switched on, not when the next call starts: the permission takes a
            // relaunch, and mid-call that splits the recording in two.
            if recordScreen, !ScreenRecorder.hasPermission {
                UserDefaults.standard.set(true, forKey: "screenAccessRequested") // Settings offers the relaunch
                CGRequestScreenCaptureAccess()
            }
        }
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
        // Otherwise the recording goes on through sleep: the room all night long.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [unowned self] _ in
            Task { @MainActor in await stopRecording() }
        }
        // So a call still on after the wake is recorded anew. Not at sleep: a check before the Mac
        // is asleep would find the call again and record it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { detector.forgetCalls() }
        }
        // Finish recordings that were cut short last time (crash, force quit, power loss). Until then
        // they're being saved: not shared, trashed or transcribed mid-save. Quitting mid-save is fine,
        // the next launch does it again.
        Task {
            let cut = store.recordings.filter { FileManager.default.fileExists(atPath: $0.partialAudioURL.path) }
            saving.formUnion(cut.map(\.id))
            for recording in cut {
                await store.finalize(recording)
                saving.remove(recording.id)
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
            Task { // after this tick, so a call that ended in it too isn't offered
                stop()
                // A call joined while this one was recorded got no prompt then: it gets one now.
                if let next = detector.active.first { callStarted(next) }
            }
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
                audio = recorder(for: recording)
                // Off the main thread: the first start blocks while macOS shows its permission prompt.
                do { try await Task.detached { try audio.start() }.value } catch {
                    try? FileManager.default.removeItem(at: recording.folder) // nothing went into it
                    throw error
                }
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
        var healAfter = Self.healAfter
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
            let diskFull = audio.isWaitingForDisk
            let problem = tick == 0 ? nil
                : !audio.hasHeardSound ? "No sound is coming in. Check Privacy & Security."
                : diskFull ? "The disk is full. Reprise keeps the call's sound until there's space."
                : stalled && stalledBefore ? "The recording stopped getting sound. Check the microphone and the free disk space."
                // Three minutes in: a waiting room is silent too.
                : tick >= 36 && session.recording.app != nil && !audio.hasHeardThem ? "No sound from the other side yet. Check System Audio Recording in Privacy & Security."
                : nil
            if let problem, problem != shown {
                log.notice("Warned: \(problem, privacy: .public)")
                show(.problem(problem), for: .seconds(8))
            }
            shown = problem
            if stalled, !diskFull { // a new microphone wouldn't make room
                log.notice("The recording stopped getting sound; restarting it on the current microphone")
                do { try await Task.detached { try audio.restart() }.value } catch {
                    log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            stalledBefore = stalled
            written = now
            // The other side went quiet while the call app still plays: a tap that stopped delivering
            // (macOS 26.5 loses one now and then), or one on audio processes the app has since replaced.
            // A new tap on the app's processes as they are now; less and less often while that doesn't help.
            let quiet = audio.secondsWithoutThem ?? 0
            if quiet < Self.healAfter { healAfter = Self.healAfter }
            if quiet >= healAfter, let app = session.recording.app, MeetingDetector.isPlaying(app) {
                healAfter = quiet * 2
                log.notice("No sound from the other side for \(Int(quiet))s while \(app.id, privacy: .public) plays; restarting the capture")
                let processes = tapped(app)
                do { try await Task.detached { try audio.restart(processes: processes) }.value } catch {
                    log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Silence from the other side this long, while the call app plays, gets the capture a new tap.
    static let healAfter: TimeInterval = 60

    /// Records the call's sound into its folder, as Settings have it.
    private func recorder(for recording: Recording) -> AudioRecorder {
        AudioRecorder(url: recording.partialAudioURL, processes: tapped(recording.app),
                      sides: UserDefaults.standard.bool(forKey: "separateTracks") ? recording.tracks.map(\.partial) : [])
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
            let audio = recorder(for: recording)
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

    /// The stops in progress, so quitting can wait until the files are written.
    @ObservationIgnored private var stopping: Task<Void, Never>?

    func stopRecording() async {
        stop()
        let task = stopping
        await task?.value
        if stopping == task { stopping = nil }
    }

    /// Stops at once; the files are finished in `stopping`.
    private func stop() {
        guard let session else { return }
        self.session = nil
        saving.insert(session.recording.id)
        // Ends after the stops before it too: the call that ended a moment ago may still be saving.
        stopping = Task { [previous = stopping] in
            await finish(session)
            await previous?.value
        }
    }

    private func finish(_ session: Session) async {
        let ended = Date.now // the stop may only finish after the Mac wakes from sleep
        let audio = session.audio
        // The screen first: the movie lasts until it stops, and the audio's stop may take seconds.
        await session.screen?.stop()
        // Off the main thread: when Reprise is the last one on a Bluetooth mic, stopping waits for
        // the headphones to leave their call mode, which can take seconds.
        await Task.detached { audio.stop() }.value
        if audio.hasHeardThem { UserDefaults.standard.set(true, forKey: "systemAudioHeard") } // Settings shows it as allowed
        var recording = session.recording
        recording.duration = ended.timeIntervalSince(recording.startedAt)
        recording.movieStart = recording.movieStart ?? Self.movieStart(in: session)
        recording = await store.finalize(recording)
        saving.remove(recording.id) // with the save, so the library opens it as done, with its player
        log.notice("Recording saved: \(recording.id, privacy: .public), \(Int(recording.duration))s")
        switch island {
        case .prompt: break // the next call's prompt still waits for an answer
        default: show(.saved(recording), for: .seconds(5))
        }
        if UserDefaults.standard.bool(forKey: TranscriptionSettings.autoKey), TranscriptionSettings.service != nil {
            transcribe(recording, then: Shortcut.runAfterCall) // with its transcript
        } else {
            Shortcut.runAfterCall(recording)
        }
    }

    /// Seconds into the audio where the movie starts.
    private static func movieStart(in session: Session) -> TimeInterval? {
        guard let audio = session.audio.startHostTime, let movie = session.screen?.startHostTime else { return nil }
        return (Double(AudioConvertHostTimeToNanos(movie)) - Double(AudioConvertHostTimeToNanos(audio))) / 1e9
    }

    /// Marks this moment of the recording, to find it on the call's wave later.
    func mark() {
        guard let session else { return }
        let at = session.audio.position ?? Date.now.timeIntervalSince(session.recording.startedAt)
        self.session?.recording.marks = (session.recording.marks ?? []) + [at]
        store.save(self.session!.recording) // kept even if Reprise quits mid-call
        log.notice("Marked \(Int(at))s")
        show(.marked(at), for: .seconds(1.5))
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
        case .marked(let at): "Marked at \(at.clock)"
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
        // The library's own: the detail may hold it from before the save set its duration.
        guard var recording = store.recordings.first(where: { $0.id == recording.id }) else { return } // trashed
        recording.title = title
        store.save(recording)
        if session?.recording.id == recording.id { session?.recording.title = title }
    }

    /// Being recorded or saved: its files aren't done yet.
    func isLive(_ recording: Recording) -> Bool { session?.recording.id == recording.id || saving.contains(recording.id) }

    /// `shown`: the library's list as it's shown, maybe searched.
    func delete(_ recording: Recording, shown: [Recording], undo: UndoManager?) {
        guard !isLive(recording) else { return } // stop first; otherwise capture continues into the Trash
        guard let trashed = store.delete(recording) else { return }
        if selection == recording.id { selection = Self.next(after: recording.id, in: shown.map(\.id)) }
        // Edit > Undo puts it back, as in Finder and Mail.
        undo?.registerUndo(withTarget: self) { model in
            guard (try? FileManager.default.moveItem(at: trashed, to: recording.folder)) != nil else { return }
            model.store.reload()
            model.selection = recording.id
        }
        undo?.setActionName("Move to Trash")
    }

    /// Selected once `id` is trashed: the call after it, or the one before when it was the last, as in
    /// Mail and Voice Memos. While searching, the next match, not a call the search hides: ⌫ would trash that next.
    static func next(after id: Recording.ID, in list: [Recording.ID]) -> Recording.ID? {
        let rest = list.filter { $0 != id }
        return rest.dropFirst(list.firstIndex(of: id) ?? 0).first ?? rest.last
    }

    /// `then`: once it's done, whether it worked or not.
    func transcribe(_ recording: Recording, then done: @escaping (Recording) -> Void = { _ in }) {
        guard !isLive(recording), transcribing[recording.id] == nil, let service = TranscriptionSettings.service else { return done(recording) }
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
            done(recording)
        }
    }
}

/// A shortcut from the Shortcuts app that gets each call's folder once it's saved: to move the
/// files, run a script on them, or send them on. What Reprise itself doesn't do, the user's own tools can.
enum Shortcut {
    static let key = "afterCallShortcut"

    static func runAfterCall(_ recording: Recording) {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty else { return }
        let run = Process()
        run.executableURL = URL(filePath: "/usr/bin/shortcuts")
        run.arguments = ["run", name, "--input-path", recording.folder.path]
        run.terminationHandler = { run in
            let status = run.terminationStatus
            Task { @MainActor in log.notice("Shortcut after the call ended with \(status)") }
        }
        do { try run.run() } catch {
            log.error("Shortcut after the call didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user's shortcuts, by name.
    @concurrent static func all() async -> [String] {
        let list = Process(), pipe = Pipe()
        list.executableURL = URL(filePath: "/usr/bin/shortcuts")
        list.arguments = ["list"]
        list.standardOutput = pipe
        guard (try? list.run()) != nil, let data = try? pipe.fileHandleForReading.readToEnd() else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// An error that is only its message.
nonisolated struct Failure: LocalizedError {
    let errorDescription: String?
}
