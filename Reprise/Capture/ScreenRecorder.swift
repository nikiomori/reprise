import ScreenCaptureKit
import Synchronization

/// Records the main display (minus Reprise's own windows) with system audio and the
/// microphone mixed in, straight to a movie file via `SCRecordingOutput`.
nonisolated final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let state = Mutex(State.recording)

    private enum State {
        case recording, finished
        case waiting(CheckedContinuation<Void, Never>)
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Records the display that shows the call: the one under the call app's largest window,
    /// otherwise the one with the menu bar.
    func start(url: URL, showing app: MeetingApp?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let area = { (rect: CGRect) in rect.isNull ? 0 : rect.width * rect.height }
        let callWindow = content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier == app?.id }
            .max { area($0.frame) < area($1.frame) }
        let underCall = callWindow.flatMap { window in
            content.displays.max { area($0.frame.intersection(window.frame)) < area($1.frame.intersection(window.frame)) }
        }
        guard let display = underCall ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let reprise = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: reprise, exceptingWindows: [])

        // Native resolution, capped so a one-hour call doesn't fill the disk.
        var size = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                          height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 2560 / max(size.width, size.height))
        size = CGSize(width: size.width * scale, height: size.height * scale)

        let config = SCStreamConfiguration()
        config.width = Int(size.width) & ~1
        config.height = Int(size.height) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = AudioObjectID.recordingMicrophone.string(kAudioDevicePropertyDeviceUID)

        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mov
        if output.availableVideoCodecTypes.contains(.hevc) { output.videoCodecType = .hevc }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Task { [self] in
            try? await Task.sleep(for: .seconds(5))
            finish() // safety net in case the delegate never reports back
        }
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if case .finished = state { continuation.resume() } else { state = .waiting(continuation) }
            }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { finish() }

    private func finish() {
        state.withLock { state in
            if case .waiting(let continuation) = state { continuation.resume() }
            state = .finished
        }
    }
}
