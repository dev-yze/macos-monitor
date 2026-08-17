import CoreGraphics
import CoreMedia
import MonitorCore
import ScreenCaptureKit

enum ScreenFrameRateStreamError: LocalizedError {
    case screenRecordingPermissionDenied
    case mainDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "未授予屏幕录制权限"
        case .mainDisplayUnavailable:
            return "未找到主显示器"
        }
    }
}

final class ScreenFrameRateStream: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrameRate: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?

    private let frameQueue = DispatchQueue(label: "com.macosmonitor.screen-frame-rate")
    private var reporter = FrameRateReporter(reportingInterval: 0.25)
    private var stream: SCStream?

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenFrameRateStreamError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw ScreenFrameRateStreamError.mainDisplayUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let refreshRate = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 60
        let requestedFrameRate = max(60, min(240, Int(refreshRate.rounded(.up))))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(requestedFrameRate))
        configuration.queueDepth = 3

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        let stream = stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete else {
            return
        }

        if let framesPerSecond = reporter.recordFrame() {
            onFrameRate?(framesPerSecond)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }
}
