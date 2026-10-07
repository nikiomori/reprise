import AVFoundation
import ScreenCaptureKit
import Synchronization
import VideoToolbox

/// Records the display that shows the call (minus Reprise's own windows) to a HEVC movie
/// without sound: the store gives it the call's sound from `audio.m4a` when the recording
/// stops, so nothing captures the microphone or the Mac's sound a second time.
///
/// Its own writer, because `SCRecordingOutput` takes no bitrate: it wrote 9–47 Mbit/s where
/// HEVC at quality 0.65 writes 0.5–6 and looks the same. The movie goes to disk in 5-second
/// fragments, so a crash costs only its last seconds.
nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "dev.nikiomori.reprise.screen", qos: .userInitiated)
    private let started = Mutex<UInt64?>(nil)

    /// Host time of the movie's first frame.
    var startHostTime: UInt64? { started.withLock { $0 } }

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

        // Native resolution, capped: past 2560 pixels a call's picture gains little but size.
        var size = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                          height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 2560 / max(size.width, size.height))
        size = CGSize(width: size.width * scale, height: size.height * scale)

        let config = SCStreamConfiguration()
        config.width = Int(size.width) & ~1
        config.height = Int(size.height) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // what the encoder takes, at 3/8 the memory of BGRA

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.65,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: 4, // seeking never decodes more than 4 s
                kVTCompressionPropertyKey_RealTime as String: true,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        (self.writer, self.input) = (writer, input)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream, let writer, let input else { return }
        self.stream = nil
        try? await stream.stopCapture()
        await withCheckedContinuation { done in queue.async { done.resume() } } // the last frame is in
        // A screen that stood still at the end still lasts until now.
        if startHostTime != nil { writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock())) }
        input.markAsFinished()
        await writer.finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only frames with new pixels: while the screen stands still, ScreenCaptureKit sends empty ones.
        guard type == .screen, let writer, let input,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap(SCFrameStatus.init) == .complete else { return }
        if startHostTime == nil {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started.withLock { $0 = CMClockConvertHostTimeToSystemUnits(buffer.presentationTimeStamp) }
        }
        if input.isReadyForMoreMediaData { input.append(buffer) } // a busy encoder drops a frame, never stalls capture
    }
}
