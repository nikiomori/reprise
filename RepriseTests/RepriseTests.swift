import AVFoundation
import CoreAudio
import EventKit
import Testing
@testable import Reprise

@MainActor struct MeetingAppTests {
    @Test(arguments: [
        ("us.zoom.xos", "Zoom"),
        ("com.google.Chrome.helper", "Google Chrome"),
        ("company.thebrowser.dia", "Dia"),
        ("company.thebrowser.browser.helper", "Arc"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("ru.yandex.desktop.telemost", "Yandex Telemost"),
    ])
    func matchesCallApps(bundleID: String, name: String) {
        #expect(MeetingApp.matching(processBundleID: bundleID)?.name == name)
    }

    @Test(arguments: ["com.apple.CoreSpeech", "com.google.Chromecast", "com.microsoft.teams2x"])
    func ignoresEverythingElse(bundleID: String) {
        #expect(MeetingApp.matching(processBundleID: bundleID) == nil)
    }
}

struct MixDownTests {
    /// Mixes interleaved Float32 streams through `AudioRecorder.mixDown`, each side into its own buffer too with `sides`.
    private func mix(_ streams: [(channels: Int, samples: [Float])], micChannels: Int, sides: Bool = false) -> (samples: [Float], you: Float, them: Float, sides: [[Float]]) {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        let samples = streams.map { stream in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: stream.samples.count)
            pointer.initialize(from: stream.samples, count: stream.samples.count)
            return pointer
        }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let you = UnsafeMutablePointer<Float>.allocate(capacity: 64), them = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer {
            samples.forEach { $0.deallocate() }
            [out, you, them].forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (i, stream) in streams.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(stream.samples.count * 4), mData: samples[i])
        }
        let (frames, youPeak, themPeak) = AudioRecorder.mixDown(list, micChannels: micChannels, into: out, sides: sides ? (you, them) : nil, capacity: 64)
        let read = { (buffer: UnsafeMutablePointer<Float>) in Array(UnsafeBufferPointer(start: buffer, count: frames)) }
        return (read(out), youPeak, themPeak, sides ? [read(you), read(them)] : [])
    }

    @Test func sumsMicAndSystem() {
        #expect(mix([(1, [0.5, -0.5]), (1, [0.25, 0.25])], micChannels: 1).samples == [0.75, -0.25])
    }

    @Test func measuresEachSideSeparately() {
        let result = mix([(2, [0.2, -0.6, 0, 0]), (1, [0.1, 0.3])], micChannels: 2)
        #expect(result.you == 0.6)
        #expect(result.them == 0.3)
    }

    @Test func averagesChannelsWithinEachSource() {
        // Stereo interleaved mic (L, R, L, R) + mono system.
        #expect(mix([(2, [0.2, 0.4, 0, 0]), (1, [0.1, 0.5])], micChannels: 2).samples == [0.3 + 0.1, 0.5])
    }

    @Test func clipsInsteadOfWrapping() {
        #expect(mix([(1, [0.9]), (1, [0.9])], micChannels: 1).samples == [1])
    }

    @Test func keepsEachSideOnItsOwn() {
        let result = mix([(2, [0.2, 0.4, 0.9, 0.9]), (1, [0.1, 0.5])], micChannels: 2, sides: true)
        #expect(result.sides == [[0.3, 0.9], [0.1, 0.5]])
        #expect(result.samples == [0.3 + 0.1, 1]) // the same mix as without the sides
    }

    @Test func staysInsideAShortBuffer() {
        #expect(mix([(1, [0.5, 0.5]), (1, [0.25])], micChannels: 1).samples == [0.75, 0.5])
    }

    /// A headset microphone at 24 kHz going into a 48 kHz file, 40 ms at a time.
    @Test func resamplesAMicrophoneAtAnotherRate() throws {
        let mic = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let converter = AVAudioConverter(from: mic, to: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)!
        let cycle = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: 960)!
        cycle.frameLength = 960
        let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096)!
        var total = 0
        for _ in 0..<25 {
            try AudioRecorder.convert(cycle, with: converter, into: out)
            total += Int(out.frameLength)
        }
        #expect(abs(total - 48_000) < 200) // a second in, a second out: the sound keeps its speed
    }
}

@MainActor struct MeetingDetectorTests {
    let zoom = MeetingApp.known.first { $0.id == "us.zoom.xos" }!
    let chrome = MeetingApp.known.first { $0.id == "com.google.Chrome" }!

    typealias Step = (after: TimeInterval, microphone: Set<MeetingApp>, audible: Set<MeetingApp>)

    /// `wakingAt`: the step the Mac wakes up before.
    private func events(_ steps: [Step], wakingAt wake: Int? = nil) -> [String] {
        let detector = MeetingDetector()
        var events: [String] = []
        detector.onStart = { events.append("start \($0.name)") }
        detector.onEnd = { events.append("end \($0.name)") }
        let start = Date.now
        for (index, step) in steps.enumerated() {
            if index == wake { detector.forgetCalls() }
            detector.update(now: start + step.after, microphone: step.microphone, audible: step.audible)
        }
        return events
    }

    @Test func callAppSurvivesALongMuteAndEndsWhenSilent() {
        let muted: [Step] = [
            (0, [zoom], [zoom]),
            (1, [zoom], [zoom]), // a quick mic check isn't a call yet
            (2, [zoom], [zoom]),
            (200, [], [zoom]), // muted for minutes with the mic closed, still playing the others
        ]
        #expect(events(muted) == ["start Zoom"])
        #expect(events(muted + [(201, [], [])]) == ["start Zoom", "end Zoom"]) // silent: the call is over
        #expect(events(muted + [(303, [], [zoom])]) == ["start Zoom", "end Zoom"]) // sound left running after the call
    }

    /// The recording stopped at sleep, so a call that goes on after the wake gets its prompt again.
    @Test func callGoingOnAfterSleepStartsAgain() {
        let call: [Step] = [(0, [zoom], [zoom]), (2, [zoom], [zoom])]
        let reconnected: [Step] = [(600, [zoom], [zoom]), (602, [zoom], [zoom])]
        #expect(events(call + reconnected) == ["start Zoom"])
        #expect(events(call + reconnected, wakingAt: 2) == ["start Zoom", "start Zoom"])
    }

    /// A call joined while another was recorded is still going on as that one ends, so it can be offered then.
    @Test func callJoinedDuringAnotherIsOnWhenThatEnds() {
        let detector = MeetingDetector()
        var goingOn: Set<MeetingApp>?
        detector.onEnd = { _ in goingOn = detector.active }
        let start = Date.now
        let steps: [(after: TimeInterval, microphone: Set<MeetingApp>)] = [(0, [zoom]), (2, [zoom]), (60, [zoom, chrome]), (62, [zoom, chrome]), (100, [chrome])]
        for step in steps { detector.update(now: start + step.after, microphone: step.microphone, audible: step.microphone) }
        #expect(goingOn == [chrome])
    }

    @Test func browserEndsSoonAfterTheMicCloses() {
        #expect(events([
            (0, [chrome], [chrome]),
            (2, [chrome], [chrome]),
            (5, [], [chrome]), // a video still playing after the call
            (13, [], [chrome]),
        ]) == ["start Google Chrome", "end Google Chrome"])
    }
}

struct WaveformTests {
    /// A short, silent file (what missing permissions produce) still fills every bar.
    @Test func silentShortFileHasAllBars() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-silent-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 50)!
        buffer.frameLength = 50
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let peaks = await Waveform.peaks(of: url, count: 120)
        #expect(peaks.count == 120)
    }
}

struct EncoderDelayTests {
    /// A click written at 1 s plays `encoderDelay` frames later: the screen recording's sound is lined up by it.
    @Test func aacStartsLateByTheEncoderDelay() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-delay-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try ADTSWriter(url: url, rate: 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for i in 48_000..<48_096 { buffer.floatChannelData![0][i] = 0.9 * sin(Float(i) * 2 * .pi / 24) } // 2 kHz
        try file.encode(buffer)
        file.close()

        let back = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(pcmFormat: back.processingFormat, frameCapacity: AVAudioFrameCount(back.length))!
        try back.read(into: read)
        let onset = UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength)).firstIndex { abs($0) > 0.2 }
        #expect(onset.map { abs($0 - (48_000 + AudioRecorder.encoderDelay)) < 24 } == true)
    }

    /// A microphone at another rate, resampled to the file's as it's recorded: 5 s in, 5 s in the file.
    @Test func aMicrophoneAtAnotherRateKeepsItsLength() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-rate-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ADTSWriter(url: url, rate: 48_000)
        let mic = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let converter = AVAudioConverter(from: mic, to: writer.format)!
        let cycle = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: 960)!
        cycle.frameLength = 960
        let resampled = AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: 4096)!
        for c in 0..<125 { // 40 ms each
            for i in 0..<960 { cycle.floatChannelData![0][i] = 0.3 * sin(Float(c * 960 + i) * 0.1) }
            try AudioRecorder.convert(cycle, with: converter, into: resampled)
            try writer.encode(resampled)
            _ = writer.writeIfDue()
        }
        writer.close()
        let seconds = Double(try AVAudioFile(forReading: url).length) / 48_000
        #expect(abs(seconds - 5) < 0.1)
    }

    /// The same bytes AVAudioFile writes, whatever the IO cycles' sizes and however often it writes.
    @Test(arguments: [48_000.0, 44_100, 24_000])
    func writesWhatAVAudioFileWrites(rate: Double) throws {
        let ours = FileManager.default.temporaryDirectory.appending(path: "reprise-ours-\(UUID()).aac")
        let theirs = FileManager.default.temporaryDirectory.appending(path: "reprise-theirs-\(UUID()).aac")
        defer { [ours, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        let writer = try ADTSWriter(url: ours, rate: rate)
        let file = try AVAudioFile(forWriting: theirs, settings: AudioRecorder.fileSettings(rate: rate), commonFormat: .pcmFormatFloat32, interleaved: false)
        let cycle = AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: 4096)!
        for c in 0..<200 {
            cycle.frameLength = [1920, 1764, 960, 4096, 37][c % 5]
            for i in 0..<Int(cycle.frameLength) { cycle.floatChannelData![0][i] = 0.3 * sin(Float(c * 4096 + i) * 0.02) }
            try writer.encode(cycle)
            _ = writer.writeIfDue()
            try file.write(from: cycle)
        }
        writer.close()
        file.close()
        #expect(try Data(contentsOf: ours) == Data(contentsOf: theirs))
    }
}

struct UpdaterTests {
    private func release(_ tag: String) -> Updater.Release {
        Updater.Release(tag_name: tag, html_url: URL(string: "https://github.com")!, assets: [])
    }

    @Test(arguments: [("v0.4.0", "0.3.0", true), ("v0.10.0", "0.9.0", true), ("0.3.1", "0.3.0", true),
                      ("v0.3.0", "0.3.0", false), ("v0.2.9", "0.3.0", false), ("v0.9.0", "0.10.0", false)])
    func comparesVersionsNumerically(tag: String, current: String, newer: Bool) {
        #expect(release(tag).isNewer(than: current) == newer)
    }
}

@MainActor struct RecordingStoreTests {
    let store = RecordingStore()

    @Test func testsGetAScratchLibrary() {
        #expect(isTesting)
        #expect(RecordingStore.root.path.contains("reprise-tests"))
    }

    @Test func recordingsInOneSecondGetTheirOwnFolders() throws {
        let date = Date(timeIntervalSince1970: 0)
        let first = try store.create(app: nil, at: date), second = try store.create(app: nil, at: date)
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0.folder) } }
        #expect(first.id != second.id)
    }

    /// The movie plays the call from its first second: the sound from before the screen recording
    /// began too, over the first frame, then the picture where it was recorded.
    @Test func movieGetsTheCallsSound() async throws {
        let recording = try await screenRecording(movieStart: 0.5)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        #expect(await store.finalize(recording).hasVideo)
        #expect(!FileManager.default.fileExists(atPath: recording.partialAudioURL.path))
        await store.finalize(recording) // again, as after a crash mid-save: nothing moves
        let movie = AVURLAsset(url: recording.videoURL)
        let sound = try await movie.loadTracks(withMediaType: .audio)
        #expect(sound.count == 1)
        let heard = try await #require(sound.first).load(.timeRange)
        #expect(heard.start == .zero && abs(heard.duration.seconds - 1.5) < 0.03) // the early half second, then the picture's second
        let frames = AVAssetImageGenerator(asset: movie)
        frames.requestedTimeToleranceBefore = .zero
        frames.requestedTimeToleranceAfter = .zero
        #expect(try await frames.image(at: .zero).actualTime == .zero) // the first frame, not black
        let second = try await frames.image(at: CMTime(value: 55, timescale: 100)).actualTime.seconds
        #expect(abs(second - (0.5 + 1.0 / 30)) < 0.002) // the second frame, as far into the sound as it was recorded
    }

    /// A crash before the movie's start was known: the call's sound plays, not a silent movie.
    @Test func withoutTheMoviesStartTheAudioPlays() async throws {
        let recording = try await screenRecording(movieStart: nil)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        #expect(await store.finalize(recording).hasVideo == false)
        #expect(FileManager.default.fileExists(atPath: recording.videoURL.path)) // still in the folder
    }

    /// Renamed while the stopped recording was still being saved: the save keeps the new title.
    @Test func renameWhileSavingStays() async throws {
        let recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        var renamed = recording
        renamed.title = "Interview"
        store.save(renamed)
        #expect(await store.finalize(recording).title == "Interview")
    }

    /// A folder duplicated or renamed in Finder is a recording of its own, so it plays and trashes itself.
    @Test func recordingIsItsFolder() throws {
        let recording = try store.create(app: nil, at: .now)
        store.save(recording)
        let copy = RecordingStore.root.appending(path: "\(recording.id) copy", directoryHint: .isDirectory)
        defer { [recording.folder, copy].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.copyItem(at: recording.folder, to: copy)
        store.reload()
        #expect(store.recordings.contains { $0.id == recording.id })
        #expect(store.recordings.first { $0.id == "\(recording.id) copy" }?.folder == copy)
    }

    /// Trashed while searching: the next match is selected, not the next call in the whole library.
    @Test func trashingSelectsTheNextCallShown() {
        #expect(AppModel.next(after: "b", in: ["a", "b", "d"]) == "d") // "c" is hidden by the search
        #expect(AppModel.next(after: "d", in: ["a", "b", "d"]) == "b")
        #expect(AppModel.next(after: "a", in: ["a"]) == nil)
    }

    /// Shared and dragged out under its title, not as one "audio.m4a" after another.
    @Test func callFileIsNamedAfterTheTitle() throws {
        var recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        recording.title = "Q3/Q4 review"
        try Data("sound".utf8).write(to: recording.finalAudioURL)
        let copy = CallFile(recording).named()
        defer { try? FileManager.default.removeItem(at: recording.copiesFolder) }
        #expect(copy.lastPathComponent == "Q3-Q4 review.m4a")
        #expect(copy.path.hasPrefix(recording.copiesFolder.path)) // where trashing the call removes it
        #expect(FileManager.default.contentsEqual(atPath: copy.path, andPath: recording.finalAudioURL.path))
    }

    /// Two seconds of sound in the crash-safe stream and a second of movie without sound, as a recording leaves them.
    private func screenRecording(movieStart: TimeInterval?) async throws -> Recording {
        var recording = try store.create(app: nil, at: .now)
        recording.hasVideo = true
        recording.movieStart = movieStart

        let file = try AVAudioFile(forWriting: recording.partialAudioURL, settings: AudioRecorder.fileSettings(rate: 48_000), commonFormat: .pcmFormatFloat32, interleaved: false)
        let sound = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 96_000)!
        sound.frameLength = 96_000
        for i in 0..<96_000 { sound.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi / 109) }
        try file.write(from: sound)
        file.close()

        let writer = try AVAssetWriter(outputURL: recording.videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            frames.append(pixels!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        store.save(recording)
        return recording
    }
}

@MainActor struct CalendarEventsTests {
    private let store = EKEventStore()

    private func event(_ title: String, from start: TimeInterval, to end: TimeInterval, allDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = .init(timeIntervalSinceReferenceDate: start * 60)
        event.endDate = .init(timeIntervalSinceReferenceDate: end * 60)
        event.isAllDay = allDay
        return event
    }

    /// The call starts at minute `at`.
    private func title(at minute: TimeInterval, _ events: [EKEvent]) -> String? {
        CalendarEvents.event(at: .init(timeIntervalSinceReferenceDate: minute * 60), among: events)?.title
    }

    @Test func picksTheEventGoingOnOrAboutToStart() {
        let standup = event("Standup", from: 600, to: 615), review = event("Review", from: 660, to: 720)
        let day = event("Offsite", from: 0, to: 1440, allDay: true)
        #expect(title(at: 605, [day, standup, review]) == "Standup")
        #expect(title(at: 652, [day, standup, review]) == "Review") // joined 8 minutes early
        #expect(title(at: 630, [day, standup, review]) == nil) // between them; never the all-day one
        #expect(title(at: 714, [event("Long", from: 540, to: 780), review]) == "Review") // the one that began last
    }
}
