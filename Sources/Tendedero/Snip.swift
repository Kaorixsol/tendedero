import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What the toolbar can do with the selection.
enum SnipAction {
    case done, pin, save, cancel, record
}

/// Chosen at the top of the screen: a still picture, or a recording.
enum SnipMode {
    case screenshot, record
}

/// Tendedero's own capture, on Cmd+Shift+A. Every screen freezes under a dim
/// veil; you pick a window or drag an area, adjust it with its handles, mark
/// it up, and finish. A finished capture is copied, saved to the screenshot
/// folder like any other, and flies onto the line from where it was taken.
/// The system's own screenshots keep working as before.
@MainActor
final class SnipSession {
    private static var current: SnipSession?
    static var isActive: Bool { current != nil }

    private var windows: [SnipWindow] = []
    private var views: [SnipView] = []
    private var previousApp: NSRunningApplication?
    /// The finished image and where it was on screen, in AppKit coordinates.
    private let onDone: (CGImage, CGRect) -> Void
    /// The screen and area to record, and whether with the system's sound.
    private let onRecord: (NSScreen, CGRect, Bool) -> Void

    private(set) var mode = SnipMode.screenshot

    /// Recording the system's sound, remembered for next time.
    var recordAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "recordAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "recordAudio") }
    }

    private init(onDone: @escaping (CGImage, CGRect) -> Void, onRecord: @escaping (NSScreen, CGRect, Bool) -> Void) {
        self.onDone = onDone
        self.onRecord = onRecord
    }

    /// - Parameter excluding: window numbers left out of the capture, so the
    ///   line itself never ends up in a screenshot.
    static func start(excluding: [Int], onDone: @escaping (CGImage, CGRect) -> Void,
                      onRecord: @escaping (NSScreen, CGRect, Bool) -> Void) {
        guard current == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            log.notice("Capture asked without screen recording permission")
            askForPermission()
            return
        }
        log.notice("Capture started")
        let session = SnipSession(onDone: onDone, onRecord: onRecord)
        current = session
        // The windows are listed before the veil goes up, so they can be
        // picked with a click.
        let windowRects = Self.windowRects()
        Task { @MainActor in
            do {
                let shots = try await capture(excluding: excluding)
                session.present(shots, windowRects: windowRects)
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                current = nil
                askForPermission()
            }
        }
    }

    // MARK: Capturing

    private static func capture(excluding: [Int]) async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { excluding.contains(Int($0.windowID)) }
        var shots: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append((screen, image))
        }
        return shots
    }

    /// Ordinary app windows on screen, front to back, in AppKit coordinates.
    private static func windowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict),
                  r.width > 40, r.height > 40 else { return nil }
            return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
        }
    }

    /// The first time, macOS asks by itself. After that it only lets you
    /// allow it in System Settings, so that is where this points.
    private static func askForPermission() {
        let askedKey = "screenCaptureAsked"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            CGRequestScreenCaptureAccess()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Tendedero needs to record the screen to take screenshots",
                              "Tendedero necesita grabar la pantalla para hacer capturas")
        alert.informativeText = L(
            "Allow it in System Settings, Privacy & Security, Screen & System Audio Recording, then try again. Your system screenshots keep working without it.",
            "Permítelo en Ajustes del Sistema, Privacidad y seguridad, Grabación de pantalla y audio del sistema, y vuelve a intentarlo. Las capturas del sistema siguen funcionando sin esto.")
        alert.addButton(withTitle: L("Open System Settings", "Abrir Ajustes del Sistema"))
        alert.addButton(withTitle: L("Cancel", "Cancelar"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: The veil

    private func present(_ shots: [(NSScreen, CGImage)], windowRects: [CGRect]) {
        guard !shots.isEmpty else {
            Self.current = nil
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        for (screen, image) in shots {
            let frame = screen.frame
            let local = windowRects.compactMap { r -> CGRect? in
                let i = r.intersection(frame)
                return i.isNull || i.width < 20 || i.height < 20 ? nil : i.offsetBy(dx: -frame.minX, dy: -frame.minY)
            }
            let window = SnipWindow(frame: frame)
            let view = SnipView(frame: CGRect(origin: .zero, size: frame.size), image: image, windowRects: local)
            view.session = self
            window.contentView = view
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let start = windows.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        windows[start].makeKey()
        windows[start].makeFirstResponder(views[start])
        views[start].pointerMoved(to: windows[start].convertPoint(fromScreen: mouse))
    }

    /// Selecting on one screen clears any selection on the others.
    func focus(_ view: SnipView) {
        for other in views where other !== view { other.reset() }
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    /// Switching on one screen switches them all.
    func setMode(_ mode: SnipMode) {
        self.mode = mode
        for view in views { view.modeChanged() }
    }

    func finish(_ action: SnipAction, from view: SnipView) {
        if action == .record, let selection = view.selection, let window = view.window, let screen = window.screen {
            let rect = selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
            let audio = recordAudio
            close(reactivate: true)
            onRecord(screen, rect, audio)
            return
        }
        guard action != .cancel, let selection = view.selection, let window = view.window,
              let image = view.render() else {
            close(reactivate: true)
            return
        }
        let rect = selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        switch action {
        case .done:
            close(reactivate: true)
            onDone(image, rect)
        case .pin:
            close(reactivate: true)
            PinnedShot.pin(image: NSImage(cgImage: image, size: rect.size), frame: rect)
        case .save:
            close(reactivate: false)
            saveAs(image)
        case .cancel, .record:
            break
        }
    }

    private func close(reactivate: Bool) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        Self.current = nil
        if reactivate { previousApp?.activate() }
    }

    private func saveAs(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName()
        panel.directoryURL = ScreenshotWatcher.desktop
        if panel.runModal() == .OK, let url = panel.url {
            Self.writePNG(image, to: url)
        }
        previousApp?.activate()
    }

    // MARK: Files

    static func fileName(_ prefix: String = "Screenshot", ext: String = "png", _ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: date)).\(ext)"
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Saves a capture into the screenshot folder the way macOS does: tagged
    /// as a screenshot, with the area it was taken from, so the watcher hangs
    /// it and it flies onto the line from there. Written under a hidden name
    /// and renamed, so it is never seen half written.
    static func saveScreenshot(_ image: CGImage, rect: CGRect, in folder: URL) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent("." + UUID().uuidString + ".png")
        guard writePNG(image, to: temp) else { return nil }
        return deliver(temp, named: fileName(), rect: rect, in: folder)
    }

    /// A finished recording goes the same way as a screenshot.
    static func saveRecording(_ file: URL, rect: CGRect, in folder: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Copied in under a hidden name first: the temporary folder may be
        // on another volume, where a move is a slow copy the watcher could see.
        let temp = folder.appendingPathComponent("." + UUID().uuidString + ".mp4")
        do {
            try fm.moveItem(at: file, to: temp)
        } catch {
            log.error("Could not save recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return deliver(temp, named: fileName("Screen Recording", ext: "mp4"), rect: rect, in: folder)
    }

    /// Tags a hidden file in the folder as a capture and gives it its name.
    private static func deliver(_ temp: URL, named name: String, rect: CGRect, in folder: URL) -> URL? {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }

        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let global: [NSNumber] = [rect.minX, mainHeight - rect.maxY, rect.width, rect.height].map { NSNumber(value: Double($0)) }
        setAttribute("com.apple.metadata:kMDItemIsScreenCapture", true, on: temp)
        setAttribute("com.apple.metadata:kMDItemScreenCaptureGlobalRect", global, on: temp)
        do {
            try fm.moveItem(at: temp, to: target)
            return target
        } catch {
            try? fm.removeItem(at: temp)
            log.error("Could not save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func setAttribute(_ name: String, _ value: Any, on url: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }
}

/// One veil per screen, over everything including the menu bar and Dock.
final class SnipWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
