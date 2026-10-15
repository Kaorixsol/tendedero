import AppKit
import AVFoundation
import SwiftUI

/// A screenshot pinned to the screen: dragged off the line with Option held,
/// it floats over every window at its own size until you close it. Drag it to
/// move it, scroll or pinch to zoom, double click to open it. The file stays
/// on the line; the pin is only another view onto it. A recording plays in
/// its pin, with controls along the bottom.
@MainActor
final class PinnedShot {
    private static var all: [PinnedShot] = []
    static var count: Int { all.count }

    /// The smallest a pin can be zoomed out to, in points wide.
    private static let minWidth: CGFloat = 120

    private let panel: PinnedPanel
    private let model = PinnedModel()

    static func pin(_ url: URL, thumb: NSImage, at point: NSPoint?) {
        let screen = point.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } }
            ?? LinePanel.screenUnderPointer() ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let center = point ?? NSPoint(x: visible.midX, y: visible.midY)

        // Its own size, as the screenshot was on screen, unless that is more
        // than most of the screen.
        let pixels = imagePixelSize(of: url)
        var size = pixels.map { CGSize(width: $0.width / screen.backingScaleFactor,
                                       height: $0.height / screen.backingScaleFactor) } ?? thumb.size
        let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())

        var frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))

        let pin = PinnedShot(image: thumb, frame: frame, url: url)
        all.append(pin)
        if isVideo(url) {
            // A recording plays in the pin, with its sound, over and over.
            pin.model.video = PinnedVideo(url: url, duration: loadVideoInfo(url, maxPixels: 16)?.duration ?? 0)
        } else {
            pin.loadSharp(url, pixels: pixels)
        }
    }

    /// A capture pinned straight from the snipping tool, right where it was
    /// taken. It has no file.
    static func pin(image: NSImage, frame: NSRect) {
        all.append(PinnedShot(image: image, frame: frame, url: nil))
    }

    static func closeAll() {
        for pin in all { pin.close() }
    }

    private init(image: NSImage, frame: NSRect, url: URL?) {
        let size = frame.size
        panel = PinnedPanel(frame: frame)
        panel.contentAspectRatio = size
        panel.minSize = CGSize(width: Self.minWidth, height: Self.minWidth * size.height / size.width)
        model.image = image

        let view = PinnedView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onOpen: { [weak self] in
                guard let url else { return }
                self?.model.video?.pause()
                NSWorkspace.shared.open(url)
            },
            onZoom: { [weak self] factor, point in self?.zoom(factor, around: point) })
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host

        panel.onEscape = { [weak self] in self?.close() }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Just pinned, it listens for Escape right away.
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
    }

    func close() {
        model.video?.stop()
        let wasKey = panel.isKeyWindow
        Self.all.removeAll { $0 === self }
        // Pressing Escape again closes the next most recent pin.
        if wasKey { Self.all.last?.panel.makeKey() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Grows or shrinks the pin keeping the point under the pointer still.
    private func zoom(_ factor: CGFloat, around point: NSPoint) {
        let f = panel.frame
        let limit = panel.screen?.frame.width ?? f.width * 4
        let width = max(Self.minWidth, min(limit, f.width * factor))
        let k = width / f.width
        guard abs(k - 1) > 0.0001 else { return }
        panel.setFrame(NSRect(x: point.x - (point.x - f.minX) * k,
                              y: point.y - (point.y - f.minY) * k,
                              width: width, height: f.height * k), display: true)
    }

    /// Shows the thumbnail at once and the full image when it is decoded.
    private func loadSharp(_ url: URL, pixels: CGSize?) {
        let maxPixels = Int(min(8000, max(480, pixels.map { max($0.width, $0.height) } ?? 3000)))
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = makeThumbnail(url, maxPixels: maxPixels)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let cg else { return }
                    self.model.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
    }
}

/// Floats over every app and Space without activating Tendedero. It is
/// resizable from its edges and keeps the photo's proportions. It takes the
/// keyboard when clicked, only to close on Escape.
final class PinnedPanel: NSPanel {
    var onEscape: () -> Void = {}

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {   // Escape
            onEscape()
            return
        }
        super.sendEvent(event)
    }

    /// The window is clear around the rounded photo, so its shadow follows
    /// the photo's shape and has to be redrawn when the size changes.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        invalidateShadow()
    }
}

/// A click on a pin that is not in front still reaches it, so the cross
/// works on the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PinnedModel: ObservableObject {
    @Published var image: NSImage?
    @Published var video: PinnedVideo?
}

/// A pinned recording: plays with sound and loops; click to pause.
@MainActor
final class PinnedVideo: ObservableObject {
    let player = AVQueuePlayer()
    let duration: Double
    @Published private(set) var isPlaying = true
    @Published private(set) var isMuted = false
    @Published private(set) var time: Double = 0

    private var looper: AVPlayerLooper?
    private var observer: Any?

    init(url: URL, duration: Double) {
        self.duration = duration
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) {
            [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0 }
        }
        player.play()
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let t = CMTime(seconds: max(0, min(1, fraction)) * duration, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        time = t.seconds
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

struct PinnedView: View {
    @ObservedObject var model: PinnedModel
    let onClose: () -> Void
    let onOpen: () -> Void
    let onZoom: (CGFloat, NSPoint) -> Void

    @State private var hovering = false

    private static let radius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let video = model.video {
                PlayerLayerView(player: video.player)
            }
            MoveArea(onClick: model.video.map { video in { video.toggle() } },
                     onDoubleClick: onOpen, onZoom: onZoom)
            if let video = model.video {
                VideoControls(video: video, visible: hovering)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .glassFrame(circle: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hovering ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.6)
            .help(L("Close", "Cerrar"))
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The bar along the bottom of a pinned recording: play, where it is, sound.
/// Shown while the pointer is over the pin, or while it is paused.
private struct VideoControls: View {
    @ObservedObject var video: PinnedVideo
    let visible: Bool

    var body: some View {
        VStack {
            Spacer()
            ViewThatFits(in: .horizontal) {
                bar(showsTime: true)
                bar(showsTime: false)
            }
            .padding(6)
        }
        .opacity(visible || !video.isPlaying ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible || !video.isPlaying)
    }

    private func bar(showsTime: Bool) -> some View {
        HStack(spacing: 8) {
            button(video.isPlaying ? "pause.fill" : "play.fill") { video.toggle() }
            if showsTime {
                Text("\(formatDuration(video.time)) / \(formatDuration(video.duration))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            Scrubber(fraction: video.duration > 0 ? video.time / video.duration : 0) { video.seek(to: $0) }
                .frame(minWidth: 30)
            button(video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { video.toggleMute() }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A thin progress line; click or drag along it to jump.
private struct Scrubber: View {
    let fraction: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 3)
                Capsule().fill(Color.white).frame(width: max(3, g.size.width * fraction), height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(value.location.x / max(g.size.width, 1))
            })
        }
        .frame(height: 18)
    }
}

/// Drags the window, opens on double click and zooms with the scroll wheel
/// or a pinch. AppKit, because SwiftUI cannot move a window by its content.
private struct MoveArea: NSViewRepresentable {
    /// A click that did not move the window, for a recording to pause.
    let onClick: (() -> Void)?
    let onDoubleClick: () -> Void
    let onZoom: (CGFloat, NSPoint) -> Void

    func makeNSView(context: Context) -> MoveView {
        let view = MoveView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MoveView, context: Context) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onZoom = onZoom
    }
}

private final class MoveView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        // The drag runs until the button is released; if the window did not
        // move, it was a click.
        let before = window?.frame
        window?.performDrag(with: event)
        if window?.frame == before { onClick?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        onZoom(max(0.8, min(1.25, 1 + delta * 0.006)), NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        onZoom(max(0.8, min(1.25, 1 + event.magnification)), NSEvent.mouseLocation)
    }
}
