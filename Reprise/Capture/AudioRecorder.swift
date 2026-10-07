import AVFoundation
import CoreAudio
import Synchronization

/// Records the microphone and everything the Mac plays (except Reprise itself) into one AAC file,
/// or only what the given processes play.
///
/// A private aggregate device combines the default input device with a system-wide
/// Core Audio process tap, so both sources share one clock (the tap is drift-compensated).
/// Each IO cycle is mixed down to mono and appended to the file.
nonisolated final class AudioRecorder: @unchecked Sendable {
    private let url: URL
    private let processes: [AudioObjectID]
    private let queue = DispatchQueue(label: "dev.nikiomori.reprise.audio", qos: .userInteractive)
    /// Start, restart and stop take turns: a restart may still be at work when the recording stops.
    private let control = NSLock()
    private var tapID = AudioObjectID.unknown
    private var deviceID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var mix: AVAudioPCMBuffer?
    /// Brings a microphone's sound to the file's rate, when it runs at another one.
    private var converter: AVAudioConverter?
    private var resampled: AVAudioPCMBuffer?
    private var rate: Double = 0
    private var micChannels = 0
    /// Host time right after the last sound in the file.
    private var end: UInt64?
    private let voices = Mutex<(you: Float, them: Float)>((0, 0))
    private let heard = Mutex(false)
    private let heardThem = Mutex(false)
    private let written = Mutex(0)
    private let started = Mutex<UInt64?>(nil)
    private var lead: UInt64 = 0 // nanoseconds

    /// `processes` empty: the whole Mac.
    init(url: URL, processes: [AudioObjectID] = []) {
        self.url = url
        self.processes = processes
    }

    /// False while nothing but silence has arrived — usually a missing privacy permission.
    var hasHeardSound: Bool { heard.withLock { $0 } }

    /// True once the Mac's sound came through — which macOS only allows with the system audio permission.
    var hasHeardThem: Bool { heardThem.withLock { $0 } }

    /// Frames that made it into the file. Stuck while the device is gone or the disk is full.
    var framesWritten: Int { written.withLock { $0 } }

    /// Host time when the sound at the file's time zero played, to line the screen recording up with it.
    var startHostTime: UInt64? { started.withLock { $0 }.map { $0 - AudioConvertNanosToHostTime(lead) } }

    /// AAC-LC opens every file with this many frames of encoder delay, and the ADTS stream doesn't
    /// say so: every player puts the first recorded frame 44 ms (at 48 kHz) into the file.
    static let encoderDelay = 2112

    static func fileSettings(rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    /// Peak of each side (0...1) since the last read: the mic, and everyone else.
    func readVoices() -> (you: Float, them: Float) { voices.withLock { peaks in defer { peaks = (0, 0) }; return peaks } }

    func start() throws {
        try control.withLock {
            do { try connect() } catch { file = nil; throw error }
        }
    }

    /// Goes on into the same file with the microphone there is now: the old one went away, taking
    /// the clock of the Mac's sound with it, or changed its rate. The time without sound becomes
    /// silence, so the screen recording stays in sync.
    func restart() throws {
        try control.withLock { try reconnect() }
    }

    func stop() {
        control.withLock {
            disconnect()
            queue.sync {
                file?.close()
                file = nil
            }
        }
    }

    private func reconnect() throws {
        guard file != nil else { return } // stopped meanwhile
        disconnect()
        try connect()
    }

    private func connect() throws {
        let mic = AudioObjectID.recordingMicrophone
        let main = mic != .unknown ? mic : AudioObjectID.defaultOutputDevice
        guard let mainUID = main.string(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(action: "find an audio device", status: kAudioHardwareBadDeviceError)
        }
        micChannels = main.channelCount(scope: kAudioObjectPropertyScopeInput)

        let tap: CATapDescription
        if processes.isEmpty {
            tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            tap.bundleIDs = [Bundle.main.bundleIdentifier ?? ""]
        } else {
            tap = CATapDescription(monoMixdownOfProcesses: processes)
            tap.isProcessRestoreEnabled = true // an audio helper that restarts mid-call comes back
        }
        tap.isPrivate = true
        try check("capture system audio", AudioHardwareCreateProcessTap(tap, &tapID))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Reprise Recorder",
            kAudioAggregateDeviceUIDKey: "dev.nikiomori.reprise.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: mainUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        do {
            try check("create the recording device", AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))

            rate = deviceID.get(kAudioDevicePropertyNominalSampleRate, Float64(48_000))
            // An IO cycle every 40 ms instead of every 10: each one wakes Reprise up, and a
            // recording needs no low latency. Measured: a quarter less CPU while recording.
            let range = deviceID.get(kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange())
            deviceID.set(kAudioDevicePropertyBufferFrameSize, UInt32(min(rate / 25, range.mMaximum)))
            if file == nil {
                // The file's time zero lies before the first IO cycle: the drift-compensated tap hands over
                // the Mac's sound late (2399 frames, 50 ms, on a MacBook), and then comes the encoder delay.
                let tapLatency = deviceID.ids(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).map { $0.get(kAudioStreamPropertyLatency, UInt32(0)) }.max() ?? 0
                lead = UInt64(Double(Int(tapLatency) + Self.encoderDelay) / rate * 1e9)
                file = try AVAudioFile(forWriting: url, settings: Self.fileSettings(rate: rate), commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let fileFormat = file!.processingFormat
            mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
            converter = rate == fileFormat.sampleRate ? nil : AVAudioConverter(from: format, to: fileFormat)
            resampled = converter == nil ? nil : AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(16_384 * fileFormat.sampleRate / rate) + 64)

            try check("start recording", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, inputTime, _, _ in
                self?.write(input, at: inputTime.pointee.mHostTime)
            })
            try check("start recording", AudioDeviceStart(deviceID, procID))
            // A call app may switch the microphone to another rate mid-call. Written on at the old
            // one, the sound would play too fast or too slow.
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let device = deviceID
            AudioObjectAddPropertyListenerBlock(device, &address, .global(qos: .userInitiated)) { [weak self] _, _ in
                guard let self else { return }
                control.withLock {
                    guard device == deviceID, device.get(kAudioDevicePropertyNominalSampleRate, rate) != rate else { return }
                    try? reconnect()
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    /// Leaves the file open for `connect()` to go on with.
    private func disconnect() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        queue.sync {} // the last IO cycle is done before its buffers change
        if deviceID != .unknown { AudioHardwareDestroyAggregateDevice(deviceID); deviceID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    private func write(_ input: UnsafePointer<AudioBufferList>, at hostTime: UInt64) {
        guard let file, let mix, let out = mix.floatChannelData?[0] else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let (frames, you, them) = Self.mixDown(buffers, micChannels: micChannels, into: out, capacity: Int(mix.frameCapacity))
        guard frames > 0 else { return }
        voices.withLock { $0 = (max($0.you, you), max($0.them, them)) }
        if you > 0 || them > 0 { heard.withLock { $0 = true } }
        if them > 0 { heardThem.withLock { $0 = true } }
        mix.frameLength = AVAudioFrameCount(frames)
        // Sound lost to a stalled cycle or a microphone change comes back as silence, so the file
        // keeps to the clock and the screen recording stays in sync with it.
        if let end, hostTime > end {
            writeSilence(Double(AudioConvertHostTimeToNanos(hostTime - end)) / 1e9, to: file)
        }
        guard (try? append(mix, to: file)) != nil else { return }
        end = hostTime + AudioConvertNanosToHostTime(UInt64(Double(frames) / rate * 1e9))
        started.withLock { $0 = $0 ?? hostTime }
        written.withLock { $0 += frames }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        guard let converter, let resampled else { return try file.write(from: buffer) }
        try Self.convert(buffer, with: converter, into: resampled)
        try file.write(from: resampled)
    }

    /// One IO cycle through a converter that keeps its state for the next one.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, into out: AVAudioPCMBuffer) throws {
        nonisolated(unsafe) var given = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            defer { given = true }
            state.pointee = given ? .noDataNow : .haveData
            return given ? nil : buffer
        }
        guard status != .error else { throw failure ?? CocoaError(.fileWriteUnknown) }
    }

    /// Gaps under 10 ms are the clocks' jitter, not lost sound.
    private func writeSilence(_ seconds: Double, to file: AVAudioFile) {
        guard seconds > 0.01, let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000) else { return }
        silence.floatChannelData![0].update(repeating: 0, count: Int(silence.frameCapacity))
        var left = AVAudioFrameCount(seconds * file.processingFormat.sampleRate)
        while left > 0 {
            silence.frameLength = min(left, silence.frameCapacity)
            guard (try? file.write(from: silence)) != nil else { return }
            left -= silence.frameLength
        }
    }

    /// Mixes one IO cycle of interleaved Float32 buffers down to mono: the average of the
    /// first `micChannels` channels (the mic — the aggregate lists sub-device streams before
    /// tap streams) plus the average of the rest (system audio), clipped to -1...1.
    /// Returns the number of frames written to `out` and the peak of each side before mixing.
    static func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer, micChannels: Int, into out: UnsafeMutablePointer<Float>, capacity: Int) -> (frames: Int, you: Float, them: Float) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return (0, 0, 0) }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0, frames <= capacity else { return (0, 0, 0) }

        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        let micWeight = micChannels > 0 ? 1 / Float(micChannels) : 0
        let systemWeight = totalChannels > micChannels ? 1 / Float(totalChannels - micChannels) : 0

        out.update(repeating: 0, count: frames)
        var you: Float = 0, them: Float = 0
        var channel = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            defer { channel += count }
            guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)) // never read past a short buffer
            for c in 0..<count {
                let isMic = channel + c < micChannels
                let weight = isMic ? micWeight : systemWeight
                var loudest: Float = 0
                for f in 0..<available {
                    let sample = data[f * count + c]
                    out[f] += sample * weight
                    loudest = max(loudest, abs(sample))
                }
                if isMic { you = max(you, loudest) } else { them = max(them, loudest) }
            }
        }
        for f in 0..<frames { out[f] = min(1, max(-1, out[f])) }
        return (frames, you, them)
    }
}
