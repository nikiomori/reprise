import AVFoundation
import CoreAudio
import Synchronization

/// Records the microphone and everything the Mac plays (except Reprise itself) into one AAC file,
/// or only what the given processes play. Each side can also go into a file of its own.
///
/// A private aggregate device combines the default input device with a system-wide
/// Core Audio process tap, so both sources share one clock (the tap is drift-compensated).
/// Each IO cycle is mixed down to mono; the files get the sound half a second at a time.
nonisolated final class AudioRecorder: @unchecked Sendable {
    private let url: URL
    /// Your microphone and everyone else, each on its own besides the mix. None: only the mix.
    private let sideURLs: [URL]
    private var processes: [AudioObjectID]
    private let queue = DispatchQueue(label: "dev.nikiomori.reprise.audio", qos: .userInteractive)
    /// Start, restart and stop take turns: a restart may still be at work when the recording stops.
    private let control = NSLock()
    private var tapID = AudioObjectID.unknown
    private var deviceID = AudioObjectID.unknown
    /// The one `connect()` picked, to tell when the default microphone changes.
    private var microphone = AudioObjectID.unknown
    private var followingMicrophone: AudioObjectPropertyListenerBlock?
    private var procID: AudioDeviceIOProcID?
    /// The mix, then the sides if any.
    private var files: [ADTSWriter] = []
    /// An IO cycle's sound for each file, at the device's rate.
    private var cycle: [AVAudioPCMBuffer] = []
    /// Bring a microphone's sound to the files' rate, when it runs at another one: one per file,
    /// as each keeps its state from cycle to cycle.
    private var converters: [AVAudioConverter?] = []
    private var resampled: [AVAudioPCMBuffer?] = []
    private var rate: Double = 0
    private var micChannels = 0
    /// Host time right after the last sound in the file.
    private var end: UInt64?
    private let voices = Mutex<(you: Float, them: Float)>((0, 0))
    private let heard = Mutex(false)
    /// Host time of the last IO cycle with the Mac's sound in it.
    private let heardThem = Mutex<UInt64?>(nil)
    private let written = Mutex(0)
    private let waitingForDisk = Mutex(false)
    private let started = Mutex<UInt64?>(nil)
    private var lead: UInt64 = 0 // nanoseconds

    /// `processes` empty: the whole Mac. `sides`: where your microphone and everyone else go on their own.
    init(url: URL, processes: [AudioObjectID] = [], sides: [URL] = []) {
        self.url = url
        self.processes = processes
        sideURLs = sides
    }

    /// False while nothing but silence has arrived — usually a missing privacy permission.
    var hasHeardSound: Bool { heard.withLock { $0 } }

    /// True once the Mac's sound came through — which macOS only allows with the system audio permission.
    var hasHeardThem: Bool { heardThem.withLock { $0 } != nil }

    /// Seconds since the Mac's sound last came through, or since the recording began if it never did.
    var secondsWithoutThem: TimeInterval? {
        guard let since = heardThem.withLock({ $0 }) ?? started.withLock({ $0 }) else { return nil }
        let now = AudioGetCurrentHostTime()
        return now > since ? Double(AudioConvertHostTimeToNanos(now - since)) / 1e9 : 0
    }

    /// Frames that made it into the file. Stuck while the device is gone or the disk is full.
    var framesWritten: Int { written.withLock { $0 } }

    /// The disk is full: the sound waits in memory, and goes into the file once there's space.
    var isWaitingForDisk: Bool { waitingForDisk.withLock { $0 } }

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
            do { try connect() } catch { files = []; throw error }
        }
        // A headset plugged in or a mic picked in Sound settings mid-call: the call app moves to it, so
        // the recording does too. One that went away is the restart's job.
        let follow: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            control.withLock {
                guard microphone != AudioObjectID.recordingMicrophone else { return }
                try? reconnect()
            }
        }
        var address = Self.defaultInput
        AudioObjectAddPropertyListenerBlock(.system, &address, .global(qos: .userInitiated), follow)
        followingMicrophone = follow
    }

    private static let defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Goes on into the same file with the microphone there is now: the old one went away, taking
    /// the clock of the Mac's sound with it, or changed its rate. The time without sound becomes
    /// silence, so the screen recording stays in sync.
    /// `processes`: the call app's audio processes as they are now, for a recording of only its sound.
    func restart(processes: [AudioObjectID] = []) throws {
        try control.withLock {
            if !self.processes.isEmpty, !processes.isEmpty { self.processes = processes }
            try reconnect()
        }
    }

    func stop() {
        if let followingMicrophone { // outside the lock, which a change in flight waits for
            var address = Self.defaultInput
            AudioObjectRemovePropertyListenerBlock(.system, &address, .global(qos: .userInitiated), followingMicrophone)
            self.followingMicrophone = nil
        }
        control.withLock {
            disconnect()
            queue.sync {
                files.forEach { $0.close() }
                files = []
            }
        }
    }

    private func reconnect() throws {
        guard !files.isEmpty else { return } // stopped meanwhile
        disconnect()
        try connect()
    }

    private func connect() throws {
        microphone = AudioObjectID.recordingMicrophone
        let main = microphone != .unknown ? microphone : AudioObjectID.defaultOutputDevice
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
            if files.isEmpty {
                // The file's time zero lies before the first IO cycle: the drift-compensated tap hands over
                // the Mac's sound late (2399 frames, 50 ms, on a MacBook), and then comes the encoder delay.
                let tapLatency = deviceID.ids(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).map { $0.get(kAudioStreamPropertyLatency, UInt32(0)) }.max() ?? 0
                lead = UInt64(Double(Int(tapLatency) + Self.encoderDelay) / rate * 1e9)
                files = try ([url] + sideURLs).map { try ADTSWriter(url: $0, rate: rate) }
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let fileFormat = files[0].format
            let resampling = rate != fileFormat.sampleRate
            cycle = files.map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)! }
            converters = files.map { _ in resampling ? AVAudioConverter(from: format, to: fileFormat) : nil }
            resampled = files.map { _ in resampling ? AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(16_384 * fileFormat.sampleRate / rate) + 64) : nil }

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

    /// Leaves the files open for `connect()` to go on with.
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
        guard let out = cycle.first?.floatChannelData?[0] else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let sides = cycle.count == 3 ? (you: cycle[1].floatChannelData![0], them: cycle[2].floatChannelData![0]) : nil
        let (frames, you, them) = Self.mixDown(buffers, micChannels: micChannels, into: out, sides: sides, capacity: Int(cycle[0].frameCapacity))
        guard frames > 0 else { return }
        voices.withLock { $0 = (max($0.you, you), max($0.them, them)) }
        if you > 0 || them > 0 { heard.withLock { $0 = true } }
        if them > 0 { heardThem.withLock { $0 = hostTime } }
        cycle.forEach { $0.frameLength = AVAudioFrameCount(frames) }
        // Sound lost to a stalled cycle or a microphone change comes back as silence, so the file
        // keeps to the clock and the screen recording stays in sync with it.
        if let end, hostTime > end {
            files.forEach { writeSilence(Double(AudioConvertHostTimeToNanos(hostTime - end)) / 1e9, to: $0) }
        }
        guard (try? files.indices.forEach(append)) != nil else { return }
        end = hostTime + AudioConvertNanosToHostTime(UInt64(Double(frames) / rate * 1e9))
        started.withLock { $0 = $0 ?? hostTime }
    }

    /// This IO cycle's sound into the file at `index`.
    private func append(_ index: Int) throws {
        let file = files[index]
        var buffer = cycle[index]
        if let converter = converters[index], let resampled = resampled[index] {
            try Self.convert(buffer, with: converter, into: resampled)
            buffer = resampled
        }
        try file.encode(buffer)
        // Every file writes when due; the mix's progress stands for all of them.
        guard file.writeIfDue(), index == 0 else { return }
        written.withLock { $0 = file.written }
        waitingForDisk.withLock { $0 = file.isWaitingForDisk }
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
    private func writeSilence(_ seconds: Double, to file: ADTSWriter) {
        guard seconds > 0.01, let silence = AVAudioPCMBuffer(pcmFormat: file.format, frameCapacity: 48_000) else { return }
        silence.floatChannelData![0].update(repeating: 0, count: Int(silence.frameCapacity))
        var left = AVAudioFrameCount(seconds * file.format.sampleRate)
        while left > 0 {
            silence.frameLength = min(left, silence.frameCapacity)
            guard (try? file.encode(silence)) != nil else { return }
            left -= silence.frameLength
        }
    }

    /// Mixes one IO cycle of interleaved Float32 buffers down to mono: the average of the
    /// first `micChannels` channels (the mic — the aggregate lists sub-device streams before
    /// tap streams) plus the average of the rest (system audio), clipped to -1...1.
    /// `sides` get each of the two averages on its own, clipped too.
    /// Returns the number of frames written to `out` and the peak of each side before mixing.
    static func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer, micChannels: Int, into out: UnsafeMutablePointer<Float>,
                        sides: (you: UnsafeMutablePointer<Float>, them: UnsafeMutablePointer<Float>)? = nil, capacity: Int) -> (frames: Int, you: Float, them: Float) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return (0, 0, 0) }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0, frames <= capacity else { return (0, 0, 0) }

        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        let micWeight = micChannels > 0 ? 1 / Float(micChannels) : 0
        let systemWeight = totalChannels > micChannels ? 1 / Float(totalChannels - micChannels) : 0

        out.update(repeating: 0, count: frames)
        sides?.you.update(repeating: 0, count: frames)
        sides?.them.update(repeating: 0, count: frames)
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
                let into = sides.map { isMic ? $0.you : $0.them } ?? out
                var loudest: Float = 0
                for f in 0..<available {
                    let sample = data[f * count + c]
                    into[f] += sample * weight
                    loudest = max(loudest, abs(sample))
                }
                if isMic { you = max(you, loudest) } else { them = max(them, loudest) }
            }
        }
        if let sides {
            for f in 0..<frames {
                out[f] = sides.you[f] + sides.them[f]
                sides.you[f] = min(1, max(-1, sides.you[f]))
                sides.them[f] = min(1, max(-1, sides.them[f]))
            }
        }
        for f in 0..<frames { out[f] = min(1, max(-1, out[f])) }
        return (frames, you, them)
    }
}

/// The recording's sound as an ADTS stream, AAC packets each behind a 7-byte header, appended to
/// the file: it plays however the recording ends. The bytes AVAudioFile writes, but kept while the
/// disk is full and written once there's space again. AVAudioFile failed for good at the first
/// write that didn't fit, and the rest of the call was lost even after space was freed.
nonisolated final class ADTSWriter {
    /// What it encodes: mono Float32 at the file's rate.
    let format: AVAudioFormat
    private let encoder: AVAudioConverter
    private let packets: AVAudioCompressedBuffer
    private let handle: FileHandle
    /// MPEG-2 ID, no CRC, AAC LC at the rate's index, one channel, "original": as AVAudioFile writes it.
    private let header: [UInt8]
    private var unwritten = Data()
    private var encoded = 0
    private var tried = 0
    /// Frames in the file.
    private(set) var written = 0
    /// The last write didn't fit: the sound waits in memory.
    private(set) var isWaitingForDisk = false

    init(url: URL, rate: Double) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let index = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350].firstIndex(of: Int(rate)),
              let aac = AVAudioFormat(settings: AudioRecorder.fileSettings(rate: rate)),
              let encoder = AVAudioConverter(from: format, to: aac) else { throw CocoaError(.featureUnsupported) }
        self.encoder = encoder
        packets = AVAudioCompressedBuffer(format: aac, packetCapacity: 32, maximumPacketSize: max(encoder.maximumOutputPacketSize, 1))
        header = [0xFF, 0xF9, UInt8(1 << 6 | index << 2), 0x60]
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    /// `nil`: the end, which gives out the encoder's last samples.
    func encode(_ buffer: AVAudioPCMBuffer?) throws {
        nonisolated(unsafe) var given = false
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            var failure: NSError?
            status = encoder.convert(to: packets, error: &failure) { _, state in
                guard let buffer, !given else {
                    state.pointee = buffer == nil ? .endOfStream : .noDataNow
                    return nil
                }
                given = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error else { throw failure ?? CocoaError(.fileWriteUnknown) }
            for packet in UnsafeBufferPointer(start: packets.packetDescriptions, count: Int(packets.packetCount)) {
                let length = 7 + Int(packet.mDataByteSize)
                unwritten.append(contentsOf: header[0..<3])
                unwritten.append(contentsOf: [header[3] | UInt8(length >> 11), UInt8(length >> 3 & 0xFF), UInt8((length & 7) << 5), 0])
                unwritten.append(packets.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self), count: Int(packet.mDataByteSize))
            }
        }
        encoded += Int(buffer?.frameLength ?? 0)
    }

    /// Writes once half a second has been encoded since the last try. Written every IO cycle, each
    /// packet went to the disk on its own: a quarter of the recording's CPU. A crash loses at most
    /// this much. True when it tried.
    func writeIfDue() -> Bool {
        guard encoded - tried >= Int(format.sampleRate / 2) else { return false }
        write()
        return true
    }

    /// Cut back when it doesn't fit, so no packet is left half written.
    private func write() {
        tried = encoded
        guard !unwritten.isEmpty, let start = try? handle.offset() else { return }
        do {
            try handle.write(contentsOf: unwritten)
            unwritten.removeAll(keepingCapacity: unwritten.count < 1 << 16) // not a full disk's backlog
            written = encoded
            isWaitingForDisk = false
        } catch {
            try? handle.truncate(atOffset: start)
            isWaitingForDisk = true
        }
    }

    /// What the encoder holds back, then all that's left, whatever fails on the way.
    func close() {
        try? encode(nil)
        write()
        try? handle.close()
    }
}
