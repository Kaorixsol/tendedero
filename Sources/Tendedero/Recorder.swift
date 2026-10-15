import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records an area of one display into an H.264 MP4, with the system's sound
/// if asked. Tendedero's own windows (the line, the border, the controls) are
/// left out of the picture. Everything after start happens on its own queue.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    /// Called on the main queue if the system stops the stream by itself.
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "app.tendedero.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var lastTime = CMTime.invalid

    init(url: URL) {
        self.url = url
    }

    /// - Parameter rect: the area in the display's points, origin at its top left.
    func start(display: SCDisplay, rect: CGRect, scale: CGFloat, audio: Bool, excluding app: SCRunningApplication?) async throws {
        // H.264 tops out at 4096 pixels on a side; a 5K area is scaled to fit.
        let fit = min(scale, 4096 / rect.width, 4096 / rect.height)
        let width = Int(rect.width * fit) & ~1, height = Int(rect.height * fit) & ~1

        let filter = SCContentFilter(display: display, excludingApplications: app.map { [$0] } ?? [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.capturesAudio = audio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        self.writer = writer
        videoInput = video

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Ends the recording. The file's URL, or nil if nothing was recorded.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let writer = self.writer, writer.status == .writing, self.started else {
                    self.writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                // The last frame lasts until the moment you stopped: a still
                // screen sends no new frames.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                writer.endSession(atSourceTime: CMTimeMaximum(now, self.lastTime))
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? self.url : nil)
                }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, let writer, writer.status == .writing else { return }
        if type == .screen {
            // Only complete frames carry a picture; idle ones only say nothing changed.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let input = videoInput else { return }
            let time = buffer.presentationTimeStamp
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            if input.isReadyForMoreMediaData {
                input.append(buffer)
                lastTime = time
            }
        } else if type == .audio {
            guard started, let input = audioInput, input.isReadyForMoreMediaData else { return }
            input.append(buffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { self.onFailure?(error) }
    }
}

/// A recording in progress: the recorder, a border around the area and a
/// small bar with the time and a stop button. Neither shows in the video.
@MainActor
final class RecordingSession: NSObject {
    private static var current: RecordingSession?
    static var isRecording: Bool { current != nil }

    private let recorder: ScreenRecorder
    private let rect: CGRect
    private let onFinish: (URL, CGRect) -> Void
    private var border: NSWindow?
    private var controls: NSPanel?
    private var timeLabel: NSTextField?
    private var timer: Timer?
    private var startDate = Date()
    private var stopping = false

    /// - Parameter rect: the area, in AppKit screen coordinates.
    static func start(on screen: NSScreen, rect: CGRect, audio: Bool, onFinish: @escaping (URL, CGRect) -> Void) {
        guard current == nil else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let session = RecordingSession(recorder: ScreenRecorder(url: temp), rect: rect, onFinish: onFinish)
        current = session
        session.begin(on: screen, audio: audio)
    }

    static func stop() {
        current?.finish()
    }

    private init(recorder: ScreenRecorder, rect: CGRect, onFinish: @escaping (URL, CGRect) -> Void) {
        self.recorder = recorder
        self.rect = rect
        self.onFinish = onFinish
        super.init()
    }

    private func begin(on screen: NSScreen, audio: Bool) {
        let frame = screen.frame
        let local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        recorder.onFailure = { [weak self] _ in self?.finish() }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == number }) else {
                    throw CocoaError(.featureUnsupported)
                }
                let me = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
                try await recorder.start(display: display, rect: local, scale: scale, audio: audio, excluding: me)
                startDate = Date()
                showChrome(on: screen)
            } catch {
                log.error("Could not start recording: \(error.localizedDescription, privacy: .public)")
                Self.current = nil
                NSSound.beep()
            }
        }
    }

    private func finish() {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        border?.orderOut(nil)
        controls?.orderOut(nil)
        let rect = rect
        Task { @MainActor in
            let url = await recorder.stop()
            Self.current = nil
            if let url { onFinish(url, rect) } else { NSSound.beep() }
        }
    }

    // MARK: Border and controls

    private func showChrome(on screen: NSScreen) {
        let border = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        border.isReleasedWhenClosed = false
        border.contentView = RecordingBorder()
        border.orderFrontRegardless()
        self.border = border

        let size = CGSize(width: 132, height: 36)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < visible.minY + 4 {
            origin.y = rect.maxY + 10
            if origin.y + size.height > visible.maxY - 4 { origin.y = rect.minY + 14 }
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let plate = NSView(frame: CGRect(origin: .zero, size: size))
        plate.wantsLayer = true
        plate.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.94).cgColor
        plate.layer?.cornerRadius = size.height / 2

        let dot = NSView(frame: CGRect(x: 14, y: size.height / 2 - 4, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.8
        blink.autoreverses = true
        blink.repeatCount = .infinity
        dot.layer?.add(blink, forKey: "blink")
        plate.addSubview(dot)

        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = CGRect(x: 30, y: size.height / 2 - 9, width: 56, height: 18)
        plate.addSubview(label)
        timeLabel = label

        let stop = NSButton(frame: CGRect(x: size.width - 40, y: 4, width: 32, height: 28))
        stop.isBordered = false
        stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: L("Stop", "Detener"))?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        stop.contentTintColor = NSColor(srgbRed: 1, green: 0.33, blue: 0.3, alpha: 1)
        stop.toolTip = L("Stop recording", "Detener la grabación")
        stop.target = self
        stop.action = #selector(stopPressed)
        plate.addSubview(stop)

        panel.contentView = plate
        panel.orderFrontRegardless()
        controls = panel

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func stopPressed() { finish() }

    private func tick() {
        timeLabel?.stringValue = formatDuration(Date().timeIntervalSince(startDate).rounded(.down))
    }
}

/// A dashed red line just outside the area being recorded.
private final class RecordingBorder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
