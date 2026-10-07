import CoreAudio

/// Typed accessors over the Core Audio property API.
nonisolated extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static var defaultInputDevice: AudioObjectID {
        system.get(kAudioHardwarePropertyDefaultInputDevice, unknown)
    }

    static var defaultOutputDevice: AudioObjectID {
        system.get(kAudioHardwarePropertyDefaultOutputDevice, unknown)
    }

    func get<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        return AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    func ids(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Total channel count across all streams in the given scope.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

struct CoreAudioError: LocalizedError {
    let action: String
    let status: OSStatus
    var errorDescription: String? { "Couldn't \(action) (Core Audio error \(status))." }
}

nonisolated func check(_ action: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CoreAudioError(action: action, status: status) }
}
