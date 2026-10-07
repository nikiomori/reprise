import AVFoundation
import CoreAudio
import Synchronization

/// Records the microphone and everything the Mac plays (except Reprise itself) into one AAC file.
///
/// A private aggregate device combines the default input device with a system-wide
/// Core Audio process tap, so both sources share one clock (the tap is drift-compensated).
/// Each IO cycle is mixed down to mono and appended to the file.
nonisolated final class AudioRecorder: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.nikiomori.reprise.audio", qos: .userInteractive)
    private var tapID = AudioObjectID.unknown
    private var deviceID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var mix: AVAudioPCMBuffer?
    private var micChannels = 0
    private let peak = Mutex<Float>(0)
    private let heard = Mutex(false)

    init(url: URL) { self.url = url }

    /// False while nothing but silence has arrived — usually a missing privacy permission.
    var hasHeardSound: Bool { heard.withLock { $0 } }

    /// Peak level (0...1) since the last read; read it from the UI at frame rate.
    func readLevel() -> Float { peak.withLock { level in defer { level = 0 }; return level } }

    func start() throws {
        let mic = AudioObjectID.defaultInputDevice
        let main = mic != .unknown ? mic : AudioObjectID.defaultOutputDevice
        guard let mainUID = main.string(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(action: "find an audio device", status: kAudioHardwareBadDeviceError)
        }
        micChannels = main.channelCount(scope: kAudioObjectPropertyScopeInput)

        let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tap.bundleIDs = [Bundle.main.bundleIdentifier ?? ""]
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

            let rate = deviceID.get(kAudioDevicePropertyNominalSampleRate, Float64(48_000))
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            mix = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: 16_384)

            try check("start recording", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
                self?.write(input)
            })
            try check("start recording", AudioDeviceStart(deviceID, procID))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        queue.sync {
            file?.close()
            file = nil
        }
        if deviceID != .unknown { AudioHardwareDestroyAggregateDevice(deviceID); deviceID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    private func write(_ input: UnsafePointer<AudioBufferList>) {
        guard let file, let mix, let out = mix.floatChannelData?[0] else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = Self.mixDown(buffers, micChannels: micChannels, into: out, capacity: Int(mix.frameCapacity))
        guard frames > 0 else { return }
        let loudest = (0..<frames).reduce(Float(0)) { max($0, abs(out[$1])) }
        peak.withLock { $0 = max($0, loudest) }
        if loudest > 0 { heard.withLock { $0 = true } }
        mix.frameLength = AVAudioFrameCount(frames)
        try? file.write(from: mix)
    }

    /// Mixes one IO cycle of interleaved Float32 buffers down to mono: the average of the
    /// first `micChannels` channels (the mic — the aggregate lists sub-device streams before
    /// tap streams) plus the average of the rest (system audio), clipped to -1...1.
    /// Returns the number of frames written to `out`.
    static func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer, micChannels: Int, into out: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return 0 }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0, frames <= capacity else { return 0 }

        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        let micWeight = micChannels > 0 ? 1 / Float(micChannels) : 0
        let systemWeight = totalChannels > micChannels ? 1 / Float(totalChannels - micChannels) : 0

        out.update(repeating: 0, count: frames)
        var channel = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            defer { channel += count }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for c in 0..<count {
                let weight = channel + c < micChannels ? micWeight : systemWeight
                for f in 0..<frames { out[f] += data[f * count + c] * weight }
            }
        }
        for f in 0..<frames { out[f] = min(1, max(-1, out[f])) }
        return frames
    }
}
