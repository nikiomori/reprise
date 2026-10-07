import AVFoundation
import CoreAudio
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
    /// Mixes interleaved Float32 streams through `AudioRecorder.mixDown`.
    private func mix(_ streams: [(channels: Int, samples: [Float])], micChannels: Int) -> (samples: [Float], you: Float, them: Float) {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        let samples = streams.map { stream in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: stream.samples.count)
            pointer.initialize(from: stream.samples, count: stream.samples.count)
            return pointer
        }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer {
            samples.forEach { $0.deallocate() }
            out.deallocate()
            free(list.unsafeMutablePointer)
        }
        for (i, stream) in streams.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(stream.samples.count * 4), mData: samples[i])
        }
        let (frames, you, them) = AudioRecorder.mixDown(list, micChannels: micChannels, into: out, capacity: 64)
        return (Array(UnsafeBufferPointer(start: out, count: frames)), you, them)
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

    @Test func staysInsideAShortBuffer() {
        #expect(mix([(1, [0.5, 0.5]), (1, [0.25])], micChannels: 1).samples == [0.75, 0.5])
    }
}

@MainActor struct MeetingDetectorTests {
    let zoom = MeetingApp.known.first { $0.id == "us.zoom.xos" }!
    let chrome = MeetingApp.known.first { $0.id == "com.google.Chrome" }!

    typealias Step = (after: TimeInterval, microphone: Set<MeetingApp>, audible: Set<MeetingApp>)

    private func events(_ steps: [Step]) -> [String] {
        let detector = MeetingDetector()
        var events: [String] = []
        detector.onStart = { events.append("start \($0.name)") }
        detector.onEnd = { events.append("end \($0.name)") }
        let start = Date.now
        for step in steps { detector.update(now: start + step.after, microphone: step.microphone, audible: step.audible) }
        return events
    }

    @Test func callAppSurvivesALongMuteAndEndsWhenSilent() {
        let muted: [Step] = [
            (0, [zoom], [zoom]),
            (1, [zoom], [zoom]), // a quick mic check isn't a call yet
            (2, [zoom], [zoom]),
            (40, [], [zoom]), // muted with the mic closed, still playing the others
        ]
        #expect(events(muted) == ["start Zoom"])
        #expect(events(muted + [(41, [], [])]) == ["start Zoom", "end Zoom"]) // silent: the call is over
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
