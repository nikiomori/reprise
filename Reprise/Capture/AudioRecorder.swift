import AVFoundation
import Accelerate
import CoreAudio
import Synchronization

/// Records the microphone and everything the Mac plays (except Reprise itself) into one AAC file,
/// or only what the given processes play. Each side can also go into a file of its own.
///
/// A private aggregate device combines the default input device with a system-wide
/// Core Audio process tap, so both sources share one clock (the tap is drift-compensated).
/// Each IO cycle is mixed down to mono and handed to `Encoding`, which writes the files.
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
    /// The files, from the first `connect()` until the stop. Behind a lock: the watch asks about the
    /// disk from the main thread while a stop may be letting go of them.
    private let encoding = Mutex<Encoding?>(nil)
    /// An IO cycle's sound for each file (the mix, then the sides if any), at the device's rate.
    private var cycle: [AVAudioPCMBuffer] = []
    private var rate: Double = 0
    private var micChannels = 0
    /// Host time right after the last sound in the file.
    private var end: UInt64?
    private let voices = Mutex<(you: Float, them: Float)>((0, 0))
    /// Only on the IO queue.
    private var leveler = Leveler()
    private let heard = Mutex(false)
    /// Host time of the last IO cycle with the Mac's sound in it.
    private let heardThem = Mutex<UInt64?>(nil)
    private let captured = Mutex(0)
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

    /// Frames the device has delivered. Stuck while it's gone.
    var framesCaptured: Int { captured.withLock { $0 } }

    /// The disk is full: the sound waits in memory, and goes into the file once there's space.
    var isWaitingForDisk: Bool { encoding.withLock { $0 }?.isWaitingForDisk ?? false }

    /// Host time when the sound at the file's time zero played, to line the screen recording up with it.
    var startHostTime: UInt64? { started.withLock { $0 }.map { $0 - AudioConvertNanosToHostTime(lead) } }

    /// Seconds into the file of the sound playing now.
    var position: TimeInterval? {
        guard let start = startHostTime else { return nil }
        let now = AudioGetCurrentHostTime()
        return now > start ? Double(AudioConvertHostTimeToNanos(now - start)) / 1e9 : 0
    }

    /// AAC-LC opens every file with this many frames of encoder delay, and the ADTS stream doesn't
    /// say so: every player puts the first recorded frame 44 ms (at 48 kHz) into the file.
    static let encoderDelay = 2112

    /// The files' rate for a microphone's. One at 88.2 kHz or more is brought down to 48: AAC has
    /// no 176.4 or 192 kHz, so such a microphone recorded nothing at all, and at 96 kHz the encoder
    /// did twice the work, and the sides took twice the space, for sound a voice doesn't have.
    static func fileRate(for rate: Double) -> Double { min(rate, 48_000) }

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
            do { try connect() } catch { encoding.withLock { $0 = nil }; throw error }
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
            encoding.withLock { $0 }?.close()
            encoding.withLock { $0 = nil }
        }
    }

    private func reconnect() throws {
        guard encoding.withLock({ $0 }) != nil else { return } // stopped meanwhile
        disconnect()
        try connect()
    }

    private func connect() throws {
        microphone = AudioObjectID.recordingMicrophone
        let main = microphone != .unknown ? microphone : AudioObjectID.defaultOutputDevice
        guard let mainUID = main.string(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(action: String(localized: "find an audio device", comment: "Completes “Couldn't …”"), status: kAudioHardwareBadDeviceError)
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
        try check(String(localized: "capture system audio", comment: "Completes “Couldn't …”"), AudioHardwareCreateProcessTap(tap, &tapID))

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
            try check(String(localized: "create the recording device", comment: "Completes “Couldn't …”"), AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))

            rate = deviceID.get(kAudioDevicePropertyNominalSampleRate, Float64(48_000))
            // An IO cycle every 40 ms instead of every 10: each one wakes Reprise up, and a
            // recording needs no low latency. Measured: a quarter less CPU while recording.
            let range = deviceID.get(kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange())
            deviceID.set(kAudioDevicePropertyBufferFrameSize, UInt32(min(rate / 25, range.mMaximum)))
            if encoding.withLock({ $0 }) == nil {
                let fileRate = Self.fileRate(for: rate)
                // The file's time zero lies before the first IO cycle: the drift-compensated tap hands over
                // the Mac's sound late (2399 frames, 50 ms, on a MacBook), and then comes the encoder delay.
                let tapLatency = deviceID.ids(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).map { $0.get(kAudioStreamPropertyLatency, UInt32(0)) }.max() ?? 0
                lead = UInt64((Double(tapLatency) / rate + Double(Self.encoderDelay) / fileRate) * 1e9)
                let files = try ([url] + sideURLs).map { $0.pathExtension == "wav" ? try WAVWriter(url: $0, rate: fileRate) as any SoundWriter : try ADTSWriter(url: $0, rate: fileRate) }
                encoding.withLock { $0 = Encoding(files: files) }
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            encoding.withLock { $0 }?.use(format) // after what came at the old rate is in the files
            cycle = ([url] + sideURLs).map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)! }

            try check(String(localized: "start recording", comment: "Completes “Couldn't …”"), AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, inputTime, _, _ in
                self?.write(input, at: inputTime.pointee.mHostTime)
            })
            try check(String(localized: "start recording", comment: "Completes “Couldn't …”"), AudioDeviceStart(deviceID, procID))
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
        guard let encoding = encoding.withLock({ $0 }), let out = cycle.first?.floatChannelData?[0] else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let sides = cycle.count == 3 ? (you: cycle[1].floatChannelData![0], them: cycle[2].floatChannelData![0]) : nil
        let (frames, you, them, power) = Self.mixDown(buffers, micChannels: micChannels, into: out, sides: sides, gains: leveler.gains, capacity: Int(cycle[0].frameCapacity))
        guard frames > 0 else { return }
        leveler.listen(you: (power.you, you), them: (power.them, them), seconds: Double(frames) / rate)
        voices.withLock { $0 = (max($0.you, you), max($0.them, them)) }
        if you > 0 || them > 0 { heard.withLock { $0 = true } }
        if them > 0 { heardThem.withLock { $0 = hostTime } }
        // Sound lost to a stalled cycle or a microphone change comes back as silence, so the file
        // keeps to the clock and the screen recording stays in sync with it.
        let lost = end.map { hostTime > $0 ? Double(AudioConvertHostTimeToNanos(hostTime - $0)) / 1e9 : 0 } ?? 0
        encoding.hand(cycle, frames: frames, after: lost)
        captured.withLock { $0 += frames }
        end = hostTime + AudioConvertNanosToHostTime(UInt64(Double(frames) / rate * 1e9))
        started.withLock { $0 = $0 ?? hostTime }
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


    /// Mixes one IO cycle of interleaved Float32 buffers down to mono: the average of the
    /// first `micChannels` channels (the mic — the aggregate lists sub-device streams before
    /// tap streams) plus the average of the rest (system audio), each at its `gains`, clipped to -1...1.
    /// `sides` get each of the two averages on its own, as they came, clipped too.
    /// Returns the number of frames written to `out`, and each side's peak and mean power before mixing.
    static func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer, micChannels: Int, into out: UnsafeMutablePointer<Float>,
                        sides: (you: UnsafeMutablePointer<Float>, them: UnsafeMutablePointer<Float>)? = nil, gains: (you: Float, them: Float) = (1, 1),
                        capacity: Int) -> (frames: Int, you: Float, them: Float, power: (you: Float, them: Float)) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return (0, 0, 0, (0, 0)) }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0, frames <= capacity else { return (0, 0, 0, (0, 0)) }

        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        let micWeight = micChannels > 0 ? 1 / Float(micChannels) : 0
        let systemWeight = totalChannels > micChannels ? 1 / Float(totalChannels - micChannels) : 0

        // vDSP down each channel of the interleaved buffers: on the realtime IO thread, a sample at a
        // time took a fortieth of the recording's CPU.
        let n = vDSP_Length(frames)
        vDSP_vclr(out, 1, n)
        if let sides { vDSP_vclr(sides.you, 1, n); vDSP_vclr(sides.them, 1, n) }
        var you: Float = 0, them: Float = 0, youEnergy: Float = 0, themEnergy: Float = 0
        var channel = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            defer { channel += count }
            guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = vDSP_Length(min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count))) // never read past a short buffer
            for c in 0..<count {
                let isMic = channel + c < micChannels
                // Into a side as it came; into the mix at the side's gain.
                var weight = (isMic ? micWeight : systemWeight) * (sides != nil ? 1 : isMic ? gains.you : gains.them)
                let into = sides.map { isMic ? $0.you : $0.them } ?? out
                vDSP_vsma(data + c, count, &weight, into, 1, into, 1, available)
                var loudest: Float = 0, energy: Float = 0
                vDSP_maxmgv(data + c, count, &loudest, available)
                vDSP_svesq(data + c, count, &energy, available)
                if isMic { you = max(you, loudest); youEnergy += energy * micWeight } else { them = max(them, loudest); themEnergy += energy * systemWeight }
            }
        }
        var low: Float = -1, high: Float = 1
        if let sides {
            var (youGain, themGain) = gains
            vDSP_vsmsma(sides.you, 1, &youGain, sides.them, 1, &themGain, out, 1, n)
            vDSP_vclip(sides.you, 1, &low, &high, sides.you, 1, n)
            vDSP_vclip(sides.them, 1, &low, &high, sides.them, 1, n)
        }
        vDSP_vclip(out, 1, &low, &high, out, 1, n)
        return (frames, you, them, (youEnergy / Float(frames), themEnergy / Float(frames)))
    }
}

/// The files' side of a recording, off the IO thread. Core Audio runs the IO block on its realtime
/// thread and waits for it: the encoders ran there, and a write to a slow disk (a server, a drive
/// spinning up) lost the call's sound for as long as it took. Here they get the sound a quarter of a
/// second at a time, at background priority; a backlog past five seconds catches up at a higher one.
nonisolated final class Encoding: @unchecked Sendable {
    /// The mix, then the sides if any. Only on `queue`.
    private var files: [any SoundWriter]
    private let queue = DispatchQueue(label: "dev.nikiomori.reprise.encoding", qos: .background)
    /// What the IO thread has handed over and the encoders haven't taken: each file's sound at the
    /// device's rate, and where in it silence goes for sound that was lost.
    private struct Handover {
        var sound: [[Float]]
        var silences: [(at: Int, seconds: Double)] = []
    }
    private let handed: Mutex<Handover>
    /// The encoders' side of the swap, so the IO thread's arrays keep their room. Only on `queue`.
    private var taken: Handover
    /// When the device's rate isn't the files': its sound a piece at a time through a resampler. Only on `queue`.
    private var pieces: [AVAudioPCMBuffer] = [], converters: [AVAudioConverter?] = [], resampled: [AVAudioPCMBuffer?] = []
    private var rate: Double = 48_000 // the device's; only on `queue`
    /// The IO thread's: frames handed over since it last asked for them to be encoded, and how many
    /// make a quarter of a second.
    private var sinceAsked = 0, quarter = 12_000
    private let waitingForDisk = Mutex(false)

    init(files: [any SoundWriter]) {
        self.files = files
        taken = Handover(sound: files.map { _ in [] })
        handed = Mutex(taken)
    }

    /// The disk is full: the sound waits in memory, and goes into the file once there's space.
    var isWaitingForDisk: Bool { waitingForDisk.withLock { $0 } }

    /// Sound comes at `format` from now on. Call it while no IO cycle runs.
    func use(_ format: AVAudioFormat) {
        queue.sync {
            drain() // what came at the old rate, through the old resamplers
            let fileFormat = files[0].format
            let resampling = format.sampleRate != fileFormat.sampleRate
            rate = format.sampleRate
            pieces = resampling ? files.map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)! } : []
            // One per file, as each keeps its state from piece to piece.
            converters = files.map { _ in resampling ? AVAudioConverter(from: format, to: fileFormat) : nil }
            resampled = files.map { _ in resampling ? AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(4096 * fileFormat.sampleRate / format.sampleRate) + 64) : nil }
            // Room for what comes between two drains and a little late, so the IO thread doesn't allocate.
            let room = Int(format.sampleRate / 3)
            for i in taken.sound.indices { taken.sound[i].reserveCapacity(room) }
            handed.withLock { for i in $0.sound.indices { $0.sound[i].reserveCapacity(room) } }
        }
        (sinceAsked, quarter) = (0, Int(format.sampleRate / 4))
    }

    /// On the IO thread: one cycle's sound for each file, after `seconds` of sound that was lost.
    /// No encoding here, and no allocation once the arrays have their room.
    func hand(_ cycle: [AVAudioPCMBuffer], frames: Int, after seconds: Double) {
        let waiting = handed.withLock { handed in
            if seconds > 0.01 { handed.silences.append((handed.sound[0].count, seconds)) } // under 10 ms: the clocks' jitter
            for (i, buffer) in cycle.enumerated() {
                handed.sound[i].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames))
            }
            return handed.sound[0].count
        }
        sinceAsked += frames
        guard sinceAsked >= quarter else { return }
        sinceAsked = 0
        if waiting > 20 * quarter {
            queue.async(qos: .userInitiated, flags: .enforceQoS) { self.drain() } // the efficiency cores fell behind
        } else {
            queue.async { self.drain() }
        }
    }

    /// What's left into the files, and the files closed, whatever fails on the way.
    func close() {
        queue.sync {
            drain()
            files.forEach { $0.close() }
            files = []
        }
    }

    /// On `queue`: all that's been handed over, into the files in order, and to the disk when due.
    private func drain() {
        handed.withLock { swap(&$0, &taken) }
        for (index, file) in files.enumerated() {
            var from = 0
            for gap in 0...taken.silences.count { // each silence, then the end
                let (at, seconds) = gap < taken.silences.count ? taken.silences[gap] : (taken.sound[index].count, 0)
                // A piece the encoder turns down still takes its time, as silence.
                if at > from, (try? encode(taken.sound[index][from..<at], into: index)) == nil {
                    writeSilence(Double(at - from) / rate, to: file)
                }
                writeSilence(seconds, to: file)
                from = at
            }
            // Every file writes when due; the mix's progress stands for all of them.
            if file.writeIfDue(), index == 0 { waitingForDisk.withLock { $0 = file.isWaitingForDisk } }
        }
        for i in taken.sound.indices { taken.sound[i].removeAll(keepingCapacity: true) }
        taken.silences.removeAll(keepingCapacity: true)
    }

    private func encode(_ sound: ArraySlice<Float>, into index: Int) throws {
        guard let converter = converters[index], let resampled = resampled[index] else {
            // At the files' rate: straight from the handed sound, in one go. Copied into pieces, each
            // piece was a call into the encoder, and each call six allocations inside it.
            return try sound.withUnsafeBufferPointer { samples in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(mutating: samples.baseAddress)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: files[index].format, bufferListNoCopy: &list) else { throw CocoaError(.fileWriteUnknown) }
                try files[index].encode(buffer)
            }
        }
        let piece = pieces[index]
        var rest = sound
        while !rest.isEmpty {
            let count = min(rest.count, Int(piece.frameCapacity))
            rest.prefix(count).withUnsafeBufferPointer { piece.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            piece.frameLength = AVAudioFrameCount(count)
            rest = rest.dropFirst(count)
            try AudioRecorder.convert(piece, with: converter, into: resampled)
            try files[index].encode(resampled)
        }
    }

    private func writeSilence(_ seconds: Double, to file: any SoundWriter) {
        guard seconds > 0.01, let silence = AVAudioPCMBuffer(pcmFormat: file.format, frameCapacity: 48_000) else { return }
        silence.floatChannelData![0].update(repeating: 0, count: Int(silence.frameCapacity))
        var left = AVAudioFrameCount(seconds * file.format.sampleRate)
        while left > 0 {
            silence.frameLength = min(left, silence.frameCapacity)
            guard (try? file.encode(silence)) != nil else { return }
            left -= silence.frameLength
        }
    }
}

/// Brings the two sides of the mix to one loudness, as a hand on two faders would: slowly, by how
/// each side's speech has sounded, never in a pause. A quiet guest comes up, a loud microphone
/// down; the sides' own files keep the sound as it came.
nonisolated struct Leveler {
    /// Where both sides' speech goes, in dBFS: clearly heard, with room for both at once.
    static let target: Float = -23
    /// Never further either way, so a whisper doesn't turn into a shout, nor a hum into a voice.
    static let range: ClosedRange<Float> = -6...9
    private(set) var gains: (you: Float, them: Float) = (1, 1)
    private var levels: (you: Float?, them: Float?) = (nil, nil)
    private var heard: (you: Double, them: Double) = (0, 0)

    /// One IO cycle of each side: its mean power and its peak.
    mutating func listen(you: (power: Float, peak: Float), them: (power: Float, peak: Float), seconds: Double) {
        let youLevel = Self.decibels(you.power), themLevel = Self.decibels(them.power)
        // Speech, not a pause: above a hush, and not just the other side coming back through the
        // speakers, which reaches the microphone 10 dB down or more.
        Self.follow(&gains.you, &levels.you, &heard.you, level: youLevel, speaking: youLevel > -50 && youLevel > themLevel - 10, peak: you.peak, seconds: seconds)
        Self.follow(&gains.them, &levels.them, &heard.them, level: themLevel, speaking: themLevel > -50 && themLevel > youLevel - 10, peak: them.peak, seconds: seconds)
    }

    private static func decibels(_ power: Float) -> Float { 10 * log10(max(power, 1e-12)) }

    private static func follow(_ gain: inout Float, _ level: inout Float?, _ heard: inout Double, level now: Float, speaking: Bool, peak: Float, seconds: Double) {
        if speaking {
            heard += seconds
            level = level.map { $0 + (now - $0) * Float(min(1, seconds / 3)) } ?? now // over the last few seconds
        }
        if heard >= 2, let level { // two seconds of speech before judging it
            let wanted = pow(10, min(max(target - level, range.lowerBound), range.upperBound) / 20)
            let step = pow(10, Float(seconds) / 20) // at most 1 dB a second: no pumping
            gain = min(max(wanted, gain / step), gain * step)
        }
        if peak * gain > 1 { gain = 1 / peak } // never into clipping: down at once, back up slowly
    }
}

/// A file the recorder writes: half a second at a time, kept whole however the recording ends, and
/// kept in memory while the disk is full.
nonisolated protocol SoundWriter: AnyObject {
    /// What it takes: mono Float32 at the file's rate.
    var format: AVAudioFormat { get }
    /// Frames in the file.
    var written: Int { get }
    /// The last write didn't fit: the sound waits in memory.
    var isWaitingForDisk: Bool { get }
    /// `nil`: the end.
    func encode(_ buffer: AVAudioPCMBuffer?) throws
    /// Writes once half a second has come since the last try. True when it tried.
    func writeIfDue() -> Bool
    func close()
}

/// The recording's sound as an ADTS stream, AAC packets each behind a 7-byte header, appended to
/// the file: it plays however the recording ends. The bytes AVAudioFile writes, but kept while the
/// disk is full and written once there's space again. AVAudioFile failed for good at the first
/// write that didn't fit, and the rest of the call was lost even after space was freed.
nonisolated final class ADTSWriter: SoundWriter {
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

/// A side without compression, for editing: 16-bit PCM in a WAV whose header is rewritten with
/// each write, so the file is whole however the recording ends and needs no repair. No encoder:
/// cheaper than AAC, at 5.8 MB a minute.
// ponytail: a WAV's sizes are 32-bit, so past 4 GB, 12 hours at 48 kHz, a side's header says 4 GB;
// players stop there. RF64 if calls ever run that long.
nonisolated final class WAVWriter: SoundWriter {
    let format: AVAudioFormat
    private let handle: FileHandle
    private var unwritten = Data()
    private var encoded = 0
    private var tried = 0
    private(set) var written = 0
    private(set) var isWaitingForDisk = false

    init(url: URL, rate: Double) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(rate: Int(rate), frames: 0)) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Starts as late as the AAC files do, by their encoder delay, so the sides line up with
        // the mix, the movie and the transcript.
        unwritten = Data(count: AudioRecorder.encoderDelay * 2)
        encoded = AudioRecorder.encoderDelay
    }

    /// One IO cycle's worth, kept from cycle to cycle.
    private var samples: [Float] = [], pcm: [Int16] = []

    func encode(_ buffer: AVAudioPCMBuffer?) throws {
        guard let buffer, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        if samples.count != count { (samples, pcm) = ([Float](repeating: 0, count: count), [Int16](repeating: 0, count: count)) }
        var scale: Float = 32767, low: Float = -32768, high: Float = 32767
        vDSP_vsmul(buffer.floatChannelData![0], 1, &scale, &samples, 1, vDSP_Length(count))
        vDSP_vclip(samples, 1, &low, &high, &samples, 1, vDSP_Length(count))
        vDSP_vfixr16(samples, 1, &pcm, 1, vDSP_Length(count))
        pcm.withUnsafeBytes { unwritten.append(contentsOf: $0) } // little-endian, as WAV wants
        encoded += count
    }

    func writeIfDue() -> Bool {
        guard encoded - tried >= Int(format.sampleRate / 2) else { return false }
        write()
        return true
    }

    /// Cut back when it doesn't fit; the header then says what's there.
    private func write() {
        tried = encoded
        guard !unwritten.isEmpty, let start = try? handle.offset() else { return }
        do {
            try handle.write(contentsOf: unwritten)
        } catch {
            try? handle.truncate(atOffset: start)
            isWaitingForDisk = true
            return
        }
        unwritten.removeAll(keepingCapacity: unwritten.count < 1 << 17)
        written = encoded
        isWaitingForDisk = false
        // The sound is in, whatever the header does: one that can't be rewritten now (a full disk
        // with a snapshot, where even an overwrite takes a new block) is rewritten with the next write.
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(rate: Int(format.sampleRate), frames: written))
        _ = try? handle.seekToEnd()
    }

    func close() {
        write()
        try? handle.close()
    }

    /// RIFF, WAVE, a `fmt ` chunk for mono 16-bit PCM, and the `data` chunk's header.
    static func header(rate: Int, frames: Int) -> Data {
        let bytes = frames * 2
        var header = Data()
        // Clamped: past 4 GB, `UInt32(value)` stopped the recording with a crash.
        let append = { (value: Int, size: Int) in withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { header.append(contentsOf: $0.prefix(size)) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes, 4)
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(16, 4)
        append(1, 2); append(1, 2) // PCM, one channel
        append(rate, 4); append(rate * 2, 4) // bytes a second
        append(2, 2); append(16, 2) // bytes a frame, bits a sample
        header.append(contentsOf: Array("data".utf8)); append(bytes, 4)
        return header
    }
}
