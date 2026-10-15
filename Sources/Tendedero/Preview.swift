import AppKit
import ImageIO
import SwiftUI

/// A large view of the photo under the pointer, shown just below the line so
/// the details of a screenshot can be read without opening it. It never takes
/// the mouse: moving off the photo is what puts it away.
@MainActor
final class Preview {
    /// How long the pointer rests on a photo before the preview opens, so
    /// sweeping across the line does not flash it.
    private static let showDelay: TimeInterval = 0.3
    /// How long the pointer can be off every photo before it closes. Enough
    /// to cross the gap between two photos without it blinking.
    private static let hideDelay: TimeInterval = 0.15
    /// Room around the card for its shadow.
    static let margin: CGFloat = 24
    /// Space between the bottom of the photo on the line and the preview.
    private static let gap: CGFloat = 10

    private let panel: NSPanel
    private let host: NSHostingView<PreviewCard>
    private let model = PreviewModel()

    private(set) var shownID: UUID?
    var windowNumber: Int { panel.windowNumber }
    private var overID: UUID?
    private var overSince: Date?
    private var offSince: Date?
    /// The sharp image of the last photo shown. A photo edited in Markup gets
    /// a new thumbnail, so the thumbnail tells whether it is still current.
    private var cache: (url: URL, thumb: ObjectIdentifier, image: NSImage)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        host = NSHostingView(rootView: PreviewCard(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Called on every tick with the photo under the pointer, if any, and
    /// where its card sits on screen.
    func update(over item: Pegged?, card: CGRect?, on screen: NSScreen?) {
        let now = Date()
        guard let item, let card, let screen else {
            overID = nil
            overSince = nil
            guard shownID != nil else { return }
            let since = offSince ?? now
            offSince = since
            if now.timeIntervalSince(since) >= Self.hideDelay { hide() }
            return
        }
        offSince = nil
        if item.id != overID {
            overID = item.id
            overSince = now
        }
        // Once open, moving to another photo follows it at once.
        if shownID != nil {
            if shownID != item.id { show(item, card: card, on: screen) }
        } else if let since = overSince, now.timeIntervalSince(since) >= Self.showDelay {
            show(item, card: card, on: screen)
        }
    }

    func hide() {
        overID = nil
        overSince = nil
        offSince = nil
        guard shownID != nil else { return }
        shownID = nil
        stopVideo()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownID == nil else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func show(_ item: Pegged, card: CGRect, on screen: NSScreen) {
        let wasShown = shownID != nil
        shownID = item.id

        let size = Self.photoSize(for: item, card: card, on: screen)
        let visible = screen.visibleFrame
        let outer = CGSize(width: size.width + 2 * (Frame.inset + Self.margin),
                           height: size.height + 2 * (Frame.inset + Self.margin))
        // Centered under the photo, kept inside the screen.
        var x = card.midX - outer.width / 2
        x = max(visible.minX, min(x, visible.maxX - outer.width))
        let top = card.minY - Self.gap + Self.margin
        let frame = NSRect(x: x, y: top - outer.height, width: outer.width, height: outer.height)

        stopVideo()
        if item.isVideo {
            // A recording plays, muted and looping, from its first frame.
            model.image = item.thumb
            model.video = LoopingPlayer(url: item.url)
        } else if let cache, cache.url == item.url, cache.thumb == ObjectIdentifier(item.thumb) {
            model.image = cache.image
        } else {
            model.image = item.thumb
            loadSharp(item, pixels: max(size.width, size.height) * screen.backingScaleFactor)
        }

        if wasShown && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    private func stopVideo() {
        model.video?.stop()
        model.video = nil
    }

    /// As large as fits between the line and the bottom of the screen, up to
    /// the screenshot's own size, so it is never blown up past sharp.
    private static func photoSize(for item: Pegged, card: CGRect, on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let chrome = 2 * (Frame.inset + margin)
        let maxW = visible.width * 0.62
        let maxH = min(visible.height * 0.75, card.minY - gap - visible.minY - 16) - chrome
        var native = item.thumb.size
        if let pixels = imagePixelSize(of: item.url) {
            native = CGSize(width: pixels.width / screen.backingScaleFactor,
                            height: pixels.height / screen.backingScaleFactor)
        }
        guard native.width > 0, native.height > 0, maxW > 0, maxH > 0 else {
            return CGSize(width: max(maxW, 100), height: max(maxH, 100))
        }
        let scale = min(maxW / native.width, maxH / native.height, 1)
        return CGSize(width: (native.width * scale).rounded(), height: (native.height * scale).rounded())
    }

    /// The thumbnail on the line is small; the sharp image is decoded off the
    /// main thread and replaces it when ready.
    private func loadSharp(_ item: Pegged, pixels: CGFloat) {
        let id = item.id, url = item.url, thumb = ObjectIdentifier(item.thumb)
        let maxPixels = Int(min(6000, max(480, pixels)))
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = makeThumbnail(url, maxPixels: maxPixels)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let cg else { return }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache = (url, thumb, image)
                    if self.shownID == id { self.model.image = image }
                }
            }
        }
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var video: LoopingPlayer?
}

/// The same glass frame as the cards on the line, only larger.
struct PreviewCard: View {
    @ObservedObject var model: PreviewModel

    private static let radius: CGFloat = 18

    var body: some View {
        Group {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // The video draws over its own first frame once it starts.
                    .overlay { if let video = model.video { PlayerLayerView(player: video.player) } }
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius - Frame.inset, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius - Frame.inset, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .padding(Frame.inset)
                    .glassFrame(cornerRadius: Self.radius)
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
            }
        }
        .padding(Preview.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
