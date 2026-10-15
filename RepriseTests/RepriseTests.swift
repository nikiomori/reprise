import AVFoundation
import Accelerate
import AppIntents
import CoreAudio
import CoreSpotlight
import EventKit
import SwiftUI
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
        ("com.apple.mobilephone", "Phone"),
        ("ru.yandex.desktop.telemost", "Yandex Telemost"),
    ])
    func matchesCallApps(bundleID: String, name: String) {
        #expect(MeetingApp.matching(processBundleID: bundleID)?.name == name)
    }

    @Test(arguments: ["com.apple.CoreSpeech", "com.google.Chromecast", "com.microsoft.teams2x"])
    func ignoresEverythingElse(bundleID: String) {
        #expect(MeetingApp.matching(processBundleID: bundleID) == nil)
    }

    /// A call in `avconferenced` is FaceTime's when it's in front or open alone, else the Phone's.
    @Test func conferenceDaemonGoesToTheCallApp() {
        let (faceTime, phone) = (MeetingApp.faceTime.id, MeetingApp.phone.id)
        #expect(MeetingApp.conferenceApp(frontmost: nil, running: []) == .phone) // answered from the notification
        #expect(MeetingApp.conferenceApp(frontmost: nil, running: [faceTime]) == .faceTime)
        #expect(MeetingApp.conferenceApp(frontmost: nil, running: [faceTime, phone]) == .phone)
        #expect(MeetingApp.conferenceApp(frontmost: faceTime, running: [faceTime, phone]) == .faceTime)
    }
}

struct MixDownTests {
    /// Mixes interleaved Float32 streams through `AudioRecorder.mixDown`, each side into its own buffer too with `sides`.
    private func mix(_ streams: [(channels: Int, samples: [Float])], micChannels: Int, sides: Bool = false, gains: (you: Float, them: Float) = (1, 1)) -> (samples: [Float], you: Float, them: Float, sides: [[Float]]) {
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
        let (frames, youPeak, themPeak, _) = AudioRecorder.mixDown(list, micChannels: micChannels, into: out, sides: sides ? (you, them) : nil, gains: gains, capacity: 64)
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

    /// The gains level the mix; the sides keep the sound as it came.
    @Test func levelsTheMixNotTheSides() {
        #expect(mix([(1, [0.2]), (1, [0.1])], micChannels: 1, gains: (0.5, 2)).samples == [0.1 + 0.2])
        let result = mix([(1, [0.2]), (1, [0.1])], micChannels: 1, sides: true, gains: (0.5, 2))
        #expect(result.sides == [[0.2], [0.1]])
        #expect(result.samples == [0.1 + 0.2])
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

struct LevelerTests {
    private let cycle = 0.04

    /// A minute of the two sides taking turns: you at −20 dBFS, a guest at −38.
    @Test func bringsAQuietGuestUpAndALoudMicDown() {
        var leveler = Leveler()
        for n in 0..<1500 {
            let yours = n / 50 % 2 == 0 // two seconds each
            leveler.listen(you: (yours ? 0.01 : 1e-7, 0.3), them: (yours ? 1e-7 : 1.6e-4, 0.05), seconds: cycle)
        }
        let decibels = { (gain: Float) in 20 * log10(gain) }
        #expect(abs(decibels(leveler.gains.you) - -3) < 0.5) // to −23
        #expect(abs(decibels(leveler.gains.them) - 9) < 0.5) // as far up as it goes
    }

    /// No speech, no judgment: silence and the other side's echo leave the gains alone.
    @Test func leavesPausesAndEchoAlone() {
        var leveler = Leveler()
        for _ in 0..<1500 { leveler.listen(you: (1e-6, 0.01), them: (1e-4, 0.05), seconds: cycle) } // you only hear their echo
        #expect(leveler.gains.you == 1)
    }

    /// Never into clipping: a shout brings the gain down at once.
    @Test func neverClips() {
        var leveler = Leveler()
        for _ in 0..<1500 { leveler.listen(you: (1e-5, 0.05), them: (1e-7, 0), seconds: cycle) } // quiet: up to +9 dB
        leveler.listen(you: (1e-2, 0.9), them: (1e-7, 0), seconds: cycle)
        #expect(leveler.gains.you * 0.9 <= 1)
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

@MainActor struct PlayerTests {
    /// Made at the first play: a seek before it only says where that play starts.
    @Test func firstPlayStartsWhereItWasSeeked() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-player-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
        silence.frameLength = 480_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence)
        let player = Player(url: url)
        player.seek(to: 4)
        #expect(player.time == 4)
        player.avPlayer.volume = 0
        player.toggle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.avPlayer.currentTime().seconds - 4) < 1)
        player.toggle()
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

    /// A bar longer than a read is put together from several, and is its own part's loudness.
    @Test func longBarsAreTheirOwnPartsLoudness() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-bars-\(UUID()).caf")
        defer { [url, url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).waveform")].forEach { try? FileManager.default.removeItem(at: $0) } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 200_001)!
        buffer.frameLength = 200_001 // a frame past the bars, left out
        for i in 0..<200_001 { buffer.floatChannelData![0][i] = (i < 100_000 ? 0.1 : 0.4) * sin(Float(i) * 0.05) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let peaks = await Waveform.peaks(of: url, count: 2)
        #expect(peaks.count == 2 && abs(peaks[0] - 0.5) < 0.01 && peaks[1] == 1) // a quarter as loud, under the square root
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
    /// A headset's 24 kHz goes up to the file's 48; a studio interface's 192 kHz comes down to them.
    @Test(arguments: [(24_000, 48_000), (192_000, AudioRecorder.fileRate(for: 192_000))] as [(Double, Double)])
    func aMicrophoneAtAnotherRateKeepsItsLength(rate: Double, fileRate: Double) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-rate-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ADTSWriter(url: url, rate: fileRate)
        let mic = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let converter = AVAudioConverter(from: mic, to: writer.format)!
        let frames = Int(rate / 25)
        let cycle = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: AVAudioFrameCount(frames))!
        cycle.frameLength = AVAudioFrameCount(frames)
        let resampled = AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: 4096)!
        for c in 0..<125 { // 40 ms each
            for i in 0..<frames { cycle.floatChannelData![0][i] = 0.3 * sin(Float(c * frames + i) * 0.1 * 24_000 / Float(rate)) }
            try AudioRecorder.convert(cycle, with: converter, into: resampled)
            try writer.encode(resampled)
            _ = writer.writeIfDue()
        }
        writer.close()
        let seconds = Double(try AVAudioFile(forReading: url).length) / fileRate
        #expect(abs(seconds - 5) < 0.1)
    }

    /// Every rate a microphone runs at gets files: AAC goes no higher than 96 kHz.
    @Test(arguments: [8_000.0, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000])
    func everyMicrophoneRateIsRecorded(rate: Double) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-rate-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ADTSWriter(url: url, rate: AudioRecorder.fileRate(for: rate)).format.sampleRate <= 48_000)
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

struct TranscriptionServiceTests {
    @Test(arguments: [("http://192.168.1.135:9001", "http://192.168.1.135:9001/v1/audio/transcriptions"),
                      ("http://localhost:8000/", "http://localhost:8000/v1/audio/transcriptions"),
                      ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/audio/transcriptions"),
                      ("http://localhost:8000/v1/audio/transcriptions", "http://localhost:8000/v1/audio/transcriptions")])
    func completesTheServerAddress(baseURL: String, endpoint: String) {
        #expect(TranscriptionService(baseURL: baseURL, model: "").endpoint?.absoluteString == endpoint)
    }

    @Test(arguments: [("http://localhost:8000/v1", true), ("http://127.0.0.1:8178/v1", true), ("http://[::1]:8000/v1", true),
                      ("http://192.168.1.135:9001", true), ("http://10.0.0.5:8000/v1", true), ("http://172.20.1.1/v1", true),
                      ("http://studio.local:8000/v1", true), ("http://[fd12::1]:8000/v1", true),
                      ("http://172.32.1.1/v1", false), ("http://10.0.0.5.nip.io/v1", false), ("https://api.openai.com/v1", false),
                      ("http://8.8.8.8/v1", false), ("http://[2001:db8::1]/v1", false), ("not a url", false)])
    func takesCallsWholeOnThisMacAndTheLocalNetwork(baseURL: String, isLocal: Bool) {
        #expect(TranscriptionService(baseURL: baseURL, model: "").isLocal == isLocal)
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

    /// Renamed and starred while the stopped recording was still being saved: the save keeps both.
    @Test func renameWhileSavingStays() async throws {
        let recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        var renamed = recording
        renamed.title = "Interview"
        renamed.favorite = true
        store.save(renamed)
        let saved = await store.finalize(recording)
        #expect(saved.title == "Interview" && saved.favorite == true)
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

    /// Pasted into an agent: who said what and when, the marks, and where the files are.
    @Test func briefHasTheTranscriptMarksAndFolder() throws {
        var recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        recording.title = "Standup"
        recording.duration = 95
        recording.marks = [62]
        recording.participants = ["Anna", "Boris"]
        let segments = [("you", 1.0, "Hi"), ("you", 3, "all"), ("1", 61, "Ship it")].map { Transcript.Segment(speaker: $0, start: $1, end: $1 + 1, text: $2) }
        try JSONEncoder().encode(Transcript(segments: segments)).write(to: recording.segmentsURL)
        store.save(recording)
        let brief = store.brief(of: recording)
        #expect(brief.hasPrefix("# Standup\n"))
        #expect(brief.contains("Files: `\(recording.folder.path)`") && brief.contains("Marked moments: 1:02"))
        #expect(brief.contains("Participants: Anna and Boris"))
        #expect(brief.hasSuffix("## Transcript\n\n[0:01] You: Hi all\n\n[1:01] Speaker 1: Ship it"))
    }

    /// A voice named in the library is named in the text that search, Copy and Spotlight read; a
    /// blank name gives it back its label.
    @Test func namedVoiceIsNamedInTheText() throws {
        let recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let segments = [("you", 1.0, "Hi"), ("1", 3, "Hello")].map { Transcript.Segment(speaker: $0, start: $1, end: $1 + 1, text: $2) }
        try JSONEncoder().encode(Transcript(segments: segments)).write(to: recording.segmentsURL)
        store.save(recording)
        store.rename(voice: "1", to: " Anna ", in: recording)
        #expect(store.transcript(of: recording) == "You: Hi\n\nAnna: Hello")
        store.rename(voice: "1", to: " ", in: recording)
        #expect(store.transcript(of: recording) == "You: Hi\n\nSpeaker 1: Hello" && store.phrases(of: recording)?.names == nil)
    }

    /// A library folder renamed in Finder is still the library; one deleted is gone.
    @Test func libraryFolderFollowsARename() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "reprise-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appending(path: "Calls", directoryHint: .isDirectory), renamed = scratch.appending(path: "Old calls", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData()
        try FileManager.default.moveItem(at: folder, to: renamed)
        #expect(RecordingStore.resolve(bookmark)?.folder.lastPathComponent == "Old calls")
        try FileManager.default.removeItem(at: renamed)
        #expect(RecordingStore.resolve(bookmark) == nil)
    }

    /// Cut to a second in the middle: the sound, the marks and the phrases with it, timed from the
    /// cut; the call as it was in the Trash.
    @Test func trimCutsEverythingAndKeepsTheCallInTheTrash() async throws {
        var recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        try twoSeconds(into: recording.finalAudioURL)
        recording.duration = 2
        recording.marks = [0.2, 1.2]
        let segments = [("you", 0.1, "Before"), ("1", 0.9, "Inside"), ("you", 1.4, "Across")].map { Transcript.Segment(speaker: $0, start: $1, end: $1 + 0.3, text: $2) }
        try JSONEncoder().encode(Transcript(segments: segments, names: ["1": "Anna"])).write(to: recording.segmentsURL)
        store.save(recording)

        let trashed = try await store.trim(recording, to: 0.5...1.5)
        defer { try? FileManager.default.removeItem(at: trashed) }
        let cut = try #require(store.recordings.first { $0.id == recording.id })
        #expect(cut.duration == 1 && cut.marks == [0.7])
        #expect(abs(try await AVURLAsset(url: cut.finalAudioURL).load(.duration).seconds - 1) < 0.05)
        let phrases = try #require(store.phrases(of: cut))
        #expect(phrases.segments.map(\.text) == ["Inside", "Across"])
        #expect(phrases.segments.map(\.start) == [0.4, 0.9] && phrases.segments.last?.end == 1)
        #expect(store.transcript(of: cut) == "Anna: Inside\n\nYou: Across") // the voices keep their names
        #expect(FileManager.default.fileExists(atPath: trashed.appending(path: "audio.m4a").path))
    }

    /// A part of the call, under its title and times, as long as asked.
    @Test func clipIsThePartUnderItsTitle() async throws {
        var recording = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: recording.folder); try? FileManager.default.removeItem(at: recording.copiesFolder) }
        try twoSeconds(into: recording.finalAudioURL)
        recording.title = "Standup"
        let clip = try await store.clip(of: recording, 0.5...1.5)
        #expect(clip.lastPathComponent == "Standup 0.00–0.01.m4a")
        #expect(abs(try await AVURLAsset(url: clip).load(.duration).seconds - 1) < 0.05)
    }

    private func twoSeconds(into url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: AudioRecorder.fileSettings(rate: 48_000), commonFormat: .pcmFormatFloat32, interleaved: false)
        let sound = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000)!
        sound.frameLength = 96_000
        for i in 0..<96_000 { sound.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi / 109) }
        try file.write(from: sound)
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

    /// A recording made elsewhere, dropped onto the library: a call under the file's name, as long as
    /// the file, which stays where it was. A call of the library's own dragged back in isn't added again.
    @Test func droppedRecordingBecomesACall() async throws {
        let name = "Interview \(UUID().uuidString)"
        let wav = FileManager.default.temporaryDirectory.appending(path: "\(name).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let sound = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000)!
        sound.frameLength = 96_000
        try file.write(from: sound)
        file.close()
        var own = try store.create(app: nil, at: .now)
        defer { try? FileManager.default.removeItem(at: own.folder); try? FileManager.default.removeItem(at: own.copiesFolder) }
        own.title = "Own call"
        try twoSeconds(into: own.finalAudioURL)

        let model = AppModel.shared
        model.add([wav, CallFile(own).named(), own.finalAudioURL])
        await model.stopRecording() // waits for it, as quitting does
        let added = try #require(model.store.recordings.first { $0.title == name })
        defer { try? FileManager.default.removeItem(at: added.folder) }
        #expect(abs(added.duration - 2) < 0.05 && !model.isLive(added))
        #expect(FileManager.default.fileExists(atPath: wav.path))
        #expect(!model.store.recordings.contains { $0.title == "Own call" || $0.title == "audio" })
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

struct TranscriptTests {
    let phrase = { (speaker: String?, start: Double, text: String) in Transcript.Segment(speaker: speaker, start: start, end: start + 2, text: text) }

    @Test func mergesSidesByTime() {
        let merged = Transcriber.merge(you: [phrase(nil, 1, "Hi"), phrase(nil, 8, "So")], them: [phrase(nil, 3, "Hello")])
        #expect(merged.segments == [phrase("you", 1, "Hi"), phrase("them", 3, "Hello"), phrase("you", 8, "So")])
        #expect(merged.text == "You: Hi\n\nOthers: Hello\n\nYou: So")
    }

    @Test func numbersTheVoicesTheServiceToldApart() {
        // Labels as the service gives them, in the order they first speak; on the microphone it's you.
        let merged = Transcriber.merge(you: [phrase("A", 4, "Me")], them: [phrase("B", 1, "One"), phrase("A", 3, "Two"), phrase("B", 6, "One again")])
        #expect(merged.segments.map(\.speaker) == ["1", "2", "you", "1"])
        // One voice is just the others; on the mix, nobody in particular.
        #expect(Transcriber.merge(you: [], them: [phrase("A", 1, "Hello")]).segments.map(\.speaker) == ["them"])
        #expect(Transcriber.numbered([phrase("A", 1, "Hello")], alone: nil).map(\.speaker) == [nil])
        #expect(Transcript(segments: [phrase(nil, 1, "Hello"), phrase(nil, 3, "there")]).text == "Hello there")
    }

    /// Shown a paragraph each time the speaker changes, and a long one cut after a phrase.
    @Test func paragraphsFollowTheSpeakers() {
        let long = String(repeating: "word ", count: 120) // 600 characters
        let segments = [phrase("you", 1, "Hi"), phrase("you", 2, "all"), phrase("1", 3, long), phrase("1", 4, long), phrase("1", 5, long), phrase("you", 6, "Bye")]
        #expect(Transcript(segments: segments).paragraphs == [0..<2, 2..<4, 4..<5, 5..<6])
    }

    /// As Find marks a document: every match, whatever its case and accents.
    /// Times from a service are shown as they come: one no clock can show reads --:--, not a crash.
    @Test(arguments: [(42.7, "0:42"), (3_725, "1:02:05"), (.nan, "--:--"), (.infinity, "--:--"), (1e30, "--:--")] as [(Double, String)])
    func clockShowsAnyTime(seconds: Double, shown: String) {
        #expect(seconds.clock == shown)
    }

    /// A transcript laid out in pieces: its paragraphs, a long one cut after its sentences, all of it kept.
    @Test func longTranscriptComesInPieces() {
        let long = (1...100).map { "Sentence number \($0) of the call, said at some length here." }.joined(separator: " ")
        let text = "You: Short.\n\nOthers: " + long
        let pieces = Paragraphs.pieces(of: text)
        #expect(pieces.first == "You: Short.")
        #expect(pieces.count > 4 && pieces.dropFirst().allSatisfy { $0.utf8.count < 1100 })
        #expect(pieces.dropFirst().joined() == "Others: " + long)
        // Without a sentence's end, cut after words.
        let words = Array(repeating: "and then we went on talking", count: 200).joined(separator: " ")
        #expect(Paragraphs.pieces(of: words).count > 4 && Paragraphs.pieces(of: words).joined() == words)
    }

    @Test func searchMarksEveryMatch() {
        let marked = AttributedString("Ship it, then ship the éclair", marking: "SHIP")
        #expect(marked.runs.filter { $0.backgroundColor != nil }.map { String(marked[$0.range].characters) } == ["Ship", "ship"])
        #expect(AttributedString("Eclair time", marking: "éclair").runs.contains { $0.backgroundColor != nil })
        #expect(AttributedString("Ship", marking: "").runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test func readsDiarizedJSON() throws {
        let answer = #"{"task":"transcribe","text":"Shall we start? Yes.","segments":[{"type":"transcript.text.segment","id":"seg_0","start":0.0,"end":1.5,"speaker":"A","text":" Shall we start?"},{"type":"transcript.text.segment","id":"seg_1","start":2.0,"end":4.0,"speaker":"B","text":"Yes."}]}"#
        let segments = try JSONDecoder().decode(Transcript.self, from: Data(answer.utf8)).segments
        #expect(segments.map(\.speaker) == ["A", "B"] && segments[1].end == 4)
    }
}

@MainActor struct RecordingControlTests {
    /// The control's extension reads what Reprise last said, in another process.
    @Test func controlSeesWhetherRepriseRecords() {
        RecordingControl.show(recording: true)
        #expect(RecordingControl.isRecording)
        RecordingControl.show(recording: false)
        #expect(!RecordingControl.isRecording)
    }
}

@MainActor struct SpotlightTests {
    /// Found by its title, the people invited and what was said.
    @Test func callIsFoundByItsTitlePeopleAndWords() {
        let recording = Recording(id: "2026-10-06 21.30.12 Zoom", title: "Standup", app: nil, startedAt: .now, duration: 95, hasVideo: false, participants: ["Anna"])
        let item = CallEntity(recording, transcript: "Ship it").attributeSet
        #expect(item.displayName == "Standup")
        #expect(item.participants == ["Anna"])
        let spotlight = CSSearchableItem(appEntity: CallEntity(recording, transcript: "Ship it"))
        #expect(spotlight.attributeSet.textContent == "Ship it")
        #expect(AppDelegate.call(fromSpotlight: spotlight.uniqueIdentifier) == recording.id) // a click on the result opens it
    }
}

struct EchoCancellerTests {
    let rate = 48_000

    /// Like speech: voiced syllables, five a second, each at a pitch of its own, in the given
    /// stretches of seconds. A sawtooth has a voice's harmonics, and AAC keeps them as it does a voice's.
    private func voice(_ seed: UInt64, in stretches: [Range<Double>], length: Int) -> [Float] {
        var state = seed
        var samples = [Float](repeating: 0, count: length), phase: Double = 0, pitch: Double = 150, low: Float = 0
        for i in 0..<length {
            let t = Double(i) / Double(rate)
            if i % (rate / 5) == 0 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                pitch = 100 + Double(state >> 40) / Double(1 << 24) * 150
            }
            phase = (phase + pitch / Double(rate)).truncatingRemainder(dividingBy: 1)
            low = 0.8 * low + 0.2 * Float(2 * phase - 1)
            guard stretches.contains(where: { $0.contains(t) }) else { continue }
            let syllable = t.truncatingRemainder(dividingBy: 0.2) / 0.15
            samples[i] = syllable < 1 ? 0.5 * low * Float(sin(.pi * syllable) * sin(.pi * syllable)) : 0
        }
        return samples
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = url.pathExtension == "wav"
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
            : AudioRecorder.fileSettings(rate: Double(rate))
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func energy(_ samples: [Float], from start: Double, to end: Double) -> Float {
        vDSP.sumOfSquares(samples[Int(start * Double(rate))..<Int(end * Double(rate))])
    }

    /// Twenty seconds: they talk, then you, then both. Their sound comes back 25 ms later, with a
    /// reflection: what a MacBook's microphone hears of its speakers.
    private func call(echo: Bool, as format: String = "m4a") throws -> (you: URL, them: URL, near: [Float]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reprise-echo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let length = 20 * rate
        let far = voice(1, in: [0..<8, 14..<20], length: length), near = voice(2, in: [8..<20], length: length)
        let delay = rate / 40
        let mic = (0..<length).map { i in
            near[i] + (echo && i >= delay + 96 ? 0.4 * far[i - delay] + 0.15 * far[i - delay - 96] : 0)
        }
        let you = folder.appending(path: "you.\(format)"), them = folder.appending(path: "them.\(format)")
        try write(mic, to: you)
        try write(far, to: them)
        return (you, them, near)
    }

    @Test(arguments: ["m4a", "wav"])
    func takesTheirEchoOutOfYourSide(format: String) throws {
        let (you, them, near) = try call(echo: true, as: format)
        defer { try? FileManager.default.removeItem(at: you.deletingLastPathComponent()) }
        let before = try read(you)
        #expect(try EchoCanceller.lag(of: you, behind: them) == rate / 40)
        #expect(try EchoCanceller.clean(you, against: them))
        let after = try read(you)
        #expect(after.count == before.count) // on the same timeline as the others and the transcript
        // Once it has learned the echo path: their voice alone, at least 20 dB quieter (28 measured).
        #expect(energy(before, from: 4, to: 8) > 100 * energy(after, from: 4, to: 8))
        // Your voice alone stays as it was, to within 1% (0.2% measured).
        let yours = vDSP.subtract(Array(after[8 * rate..<14 * rate]), Array(near[8 * rate..<14 * rate]))
        #expect(vDSP.sumOfSquares(yours) < 0.01 * energy(near, from: 8, to: 14))
    }

    @Test func withHeadphonesYourSideStaysAsItIs() throws {
        let (you, them, _) = try call(echo: false)
        defer { try? FileManager.default.removeItem(at: you.deletingLastPathComponent()) }
        let before = try Data(contentsOf: you)
        #expect(try !EchoCanceller.clean(you, against: them))
        #expect(try Data(contentsOf: you) == before)
    }
}

/// The files' side of a recording, fed as the IO thread feeds it: 40 ms cycles at the device's rate.
struct EncodingTests {
    /// One cycle: a buffer for each file, each holding its value.
    private func cycles(_ values: [Float], rate: Double) -> [AVAudioPCMBuffer] {
        values.map { value in
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: AVAudioFrameCount(rate / 25))!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: value, count: Int(buffer.frameLength))
            return buffer
        }
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// The cycles in the order they came, and lost sound as silence where it was lost.
    @Test func cyclesAndSilenceInOrder() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoding = Encoding(files: [try WAVWriter(url: url, rate: 48_000)])
        encoding.use(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        for (value, lost) in [(0.25, 0.0), (0.5, 0.005), (-0.5, 0.1)] as [(Float, Double)] {
            let cycle = cycles([value], rate: 48_000)
            encoding.hand(cycle, frames: 1920, after: lost)
        }
        encoding.close()
        let samples = try read(url), delay = AudioRecorder.encoderDelay
        #expect(samples.count == delay + 3 * 1920 + 4800) // 5 ms is the clocks' jitter, not lost sound
        #expect(samples[delay..<delay + 1920].allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(samples[delay + 1920..<delay + 3840].allSatisfy { abs($0 - 0.5) < 0.001 })
        #expect(samples[delay + 3840..<delay + 3840 + 4800].allSatisfy { $0 == 0 })
        #expect(samples[(delay + 3840 + 4800)...].allSatisfy { abs($0 + 0.5) < 0.001 })
    }

    /// Ten seconds, encoded half a second at a time behind the cycles, and all of it in the file.
    @Test func everythingHandedIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoding = Encoding(files: [try WAVWriter(url: url, rate: 48_000)])
        encoding.use(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        for n in 0..<250 { encoding.hand(cycles([Float(n) / 1000], rate: 48_000), frames: 1920, after: 0) }
        encoding.close()
        let samples = try read(url)
        #expect(samples.count == AudioRecorder.encoderDelay + 250 * 1920)
        #expect(abs(samples[AudioRecorder.encoderDelay + 249 * 1920] - 0.249) < 0.001)
    }

    /// Encoded straight from the handed sound, in quarter seconds: the sound a writer fed cycle by cycle
    /// writes, to the same length. Not the same bytes: the encoder rounds a little differently with how
    /// much it gets at a time (-99 dB). A sample lost or doubled would be 0 dB.
    @Test func encodesWhatAWriterFedDirectlyWrites() throws {
        let urls = (0..<2).map { _ in FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).aac") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let encoding = Encoding(files: [try ADTSWriter(url: urls[0], rate: 48_000)])
        let direct = try ADTSWriter(url: urls[1], rate: 48_000)
        encoding.use(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        let cycle = cycles([0], rate: 48_000)
        for n in 0..<75 { // three seconds
            for i in 0..<1920 { cycle[0].floatChannelData![0][i] = 0.3 * sin(Float(n * 1920 + i) * 0.02) }
            encoding.hand(cycle, frames: 1920, after: 0)
            try direct.encode(cycle[0])
        }
        encoding.close()
        direct.close()
        let (handed, fed) = (try read(urls[0]), try read(urls[1]))
        #expect(handed.count == fed.count)
        let apart = zip(handed, fed).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }, loud = fed.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(apart < loud * 1e-6) // 60 dB under the sound
    }

    /// A headset at 24 kHz into 48 kHz files, then a microphone at 48 kHz: a second each, two in the file.
    @Test func aMicrophoneChangingRateKeepsTheLength() throws {
        let urls = (0..<2).map { _ in FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).wav") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let encoding = Encoding(files: try urls.map { try WAVWriter(url: $0, rate: 48_000) })
        for rate in [24_000.0, 48_000] {
            encoding.use(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!)
            for _ in 0..<25 { encoding.hand(cycles([0.3, -0.3], rate: rate), frames: Int(rate / 25), after: 0) }
        }
        encoding.close()
        for url in urls { #expect(abs(try read(url).count - (AudioRecorder.encoderDelay + 96_000)) < 100) }
    }
}

struct WAVWriterTests {
    /// Thirteen hours in, past what a WAV's sizes hold: the header says as much as it can.
    @Test func headerOfASidePast4GB() {
        let header = WAVWriter.header(rate: 48_000, frames: 13 * 3600 * 48_000)
        #expect(header.count == 44)
        #expect(header.suffix(4) == Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    /// A second of a tone, 40 ms at a time, as the recorder hands it over.
    private func record(into url: URL, closing: Bool) throws -> WAVWriter {
        let writer = try WAVWriter(url: url, rate: 48_000)
        let cycle = AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: 1920)!
        cycle.frameLength = 1920
        for n in 0..<25 {
            for i in 0..<1920 { cycle.floatChannelData![0][i] = 0.5 * sin(Float(n * 1920 + i) * 2 * .pi / 48) }
            try writer.encode(cycle)
            _ = writer.writeIfDue()
        }
        if closing { writer.close() }
        return writer
    }

    /// The tone, after the AAC files' encoder delay of silence, so the sides line up with the mix.
    @Test func writesWhatItGets() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try record(into: url, closing: true)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == Int64(AudioRecorder.encoderDelay + 48_000))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(samples.prefix(AudioRecorder.encoderDelay).allSatisfy { $0 == 0 })
        #expect(abs(samples[AudioRecorder.encoderDelay + 12] - 0.5) < 0.001) // a quarter of the tone's period in
    }

    /// Cut short without a close, as by a crash: what was written plays.
    @Test func playsWithoutAClose() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try record(into: url, closing: false)
        #expect(writer.written > 24_000)
        #expect(try AVAudioFile(forReading: url).length == Int64(writer.written))
    }
}
