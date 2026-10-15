import AppKit

enum SnipTool: CaseIterable {
    case rect, ellipse, line, arrow, pen, text, mosaic, number
}

/// One annotation, in the view's coordinates.
struct SnipMark {
    var tool: SnipTool
    var color: NSColor
    /// Small, medium or large: 0, 1 or 2.
    var size: Int
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 0
    /// For the mosaic: the area, already pixelated.
    var mosaic: CGImage?

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func lineWidth(_ size: Int) -> CGFloat { [2, 4, 7][size] }
    static func fontSize(_ size: Int) -> CGFloat { [16, 22, 30][size] }
    static func radius(_ size: Int) -> CGFloat { [11, 14, 18][size] }

    /// Whether the gesture made something worth keeping, not a stray click.
    var isMeaningful: Bool {
        switch tool {
        case .pen: return points.count > 1
        case .line, .arrow: return hypot(end.x - start.x, end.y - start.y) > 3
        case .rect, .ellipse, .mosaic: return rect.width > 3 && rect.height > 3
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return true
        }
    }

    static func textAttributes(color: NSColor, size: Int) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize(size), weight: .semibold), .foregroundColor: color]
    }

    /// Draws into the current graphics context, on screen and in the final image alike.
    func draw() {
        let width = Self.lineWidth(size)
        color.set()
        switch tool {
        case .rect:
            let path = NSBezierPath(rect: rect)
            path.lineWidth = width
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = width
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        case .arrow:
            drawArrow(width: width)
        case .pen:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .text:
            let string = NSAttributedString(string: text, attributes: Self.textAttributes(color: color, size: size))
            let height = string.size().height
            string.draw(at: CGPoint(x: start.x, y: start.y - height))
        case .mosaic:
            guard let mosaic, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(mosaic, in: rect)
            ctx.restoreGState()
        case .number:
            let r = Self.radius(size)
            let circle = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let s = label.size()
            label.draw(at: CGPoint(x: start.x - s.width / 2, y: start.y - s.height / 2))
        }
    }

    private func drawArrow(width: CGFloat) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let head = min(length, max(14, width * 4.5))
        let spread: CGFloat = .pi / 7
        let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: base)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.stroke()

        let tip = NSBezierPath()
        tip.move(to: end)
        tip.line(to: CGPoint(x: end.x - cos(angle - spread) * head, y: end.y - sin(angle - spread) * head))
        tip.line(to: CGPoint(x: end.x - cos(angle + spread) * head, y: end.y - sin(angle + spread) * head))
        tip.close()
        tip.fill()
    }
}

/// The frozen screen under a veil. First it picks an area, then it becomes
/// the editor for it: handles to adjust it, the toolbar to mark it up.
@MainActor
final class SnipView: NSView, NSTextFieldDelegate {
    let image: CGImage
    private let windowRects: [CGRect]
    weak var session: SnipSession?

    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    private var marks: [SnipMark] = []
    private var drawing: SnipMark?
    private var tool: SnipTool?
    private var color = SnipToolbar.colors[0]
    private var size = 1

    private enum Drag {
        case none
        case creating(CGPoint)
        case moving(CGPoint, CGRect)
        case resizing(Handle, CGRect)
        case marking
    }
    private var drag = Drag.none

    private var textField: NSTextField?
    private var textOrigin = CGPoint.zero
    private let toolbar = SnipToolbar()
    private let modeSwitch = ModeSwitch()

    private var mode: SnipMode { session?.mode ?? .screenshot }
    /// What Return, a double click and the green button do in this mode.
    private var primaryAction: SnipAction { mode == .record ? .record : .done }

    private static let accent = NSColor(srgbRed: 0.16, green: 0.53, blue: 1, alpha: 1)

    /// Pixels per point of the frozen image.
    private var scale: CGFloat { CGFloat(image.width) / max(bounds.width, 1) }

    init(frame: NSRect, image: CGImage, windowRects: [CGRect]) {
        self.image = image
        self.windowRects = windowRects
        super.init(frame: frame)
        toolbar.isHidden = true
        toolbar.onTool = { [weak self] t in self?.choose(t) }
        toolbar.onColor = { [weak self] c in self?.color = c; self?.syncToolbar() }
        toolbar.onSize = { [weak self] s in self?.size = s; self?.syncToolbar() }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onAction = { [weak self] action in
            guard let self else { return }
            self.commitText()
            self.session?.finish(action, from: self)
        }
        toolbar.onAudio = { [weak self] in
            guard let session = self?.session else { return }
            session.recordAudio.toggle()
            self?.syncToolbar()
        }
        addSubview(toolbar)

        let size = modeSwitch.frame.size
        modeSwitch.setFrameOrigin(CGPoint(x: (frame.width - size.width) / 2, y: frame.height - size.height - 44))
        modeSwitch.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        modeSwitch.onChange = { [weak self] mode in self?.session?.setMode(mode) }
        addSubview(modeSwitch)
        syncToolbar()
    }

    /// The session switched between screenshot and recording.
    func modeChanged() {
        commitText()
        if mode == .record {
            // Marks belong to pictures; a recording has none.
            marks.removeAll()
            drawing = nil
            tool = nil
        }
        modeSwitch.mode = mode
        syncToolbar()
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Back to picking an area, as when the veil first went up.
    func reset() {
        commitText()
        selection = nil
        hoverRect = nil
        marks.removeAll()
        drawing = nil
        tool = nil
        drag = .none
        toolbar.isHidden = true
        syncToolbar()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)

        let veil = NSBezierPath(rect: bounds)
        if let clear = selection ?? hoverRect {
            veil.append(NSBezierPath(rect: clear))
            veil.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        veil.fill()

        if let sel = selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: sel).addClip()
            for mark in marks { mark.draw() }
            drawing?.draw()
            NSGraphicsContext.restoreGraphicsState()

            Self.accent.setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            for handle in Handle.all {
                let p = handle.point(in: sel)
                let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                NSColor.white.setFill()
                dot.fill()
                Self.accent.setStroke()
                dot.lineWidth = 1.2
                dot.stroke()
            }
            drawSizeLabel(for: sel)
        } else if let hover = hoverRect {
            Self.accent.setStroke()
            let border = NSBezierPath(rect: hover.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()
        }
    }

    private func drawSizeLabel(for sel: CGRect) {
        let label = NSAttributedString(string: "\(Int(sel.width)) x \(Int(sel.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let s = label.size()
        var box = CGRect(x: sel.minX, y: sel.maxY + 6, width: s.width + 12, height: s.height + 6)
        if box.maxY > bounds.maxY - 2 { box.origin.y = sel.maxY - box.height - 6; box.origin.x += 6 }
        box.origin.x = min(box.minX, bounds.maxX - box.width - 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    // MARK: Pointer

    func pointerMoved(to p: CGPoint) {
        if selection == nil {
            let hover = windowRects.first { $0.contains(p) }
            if hover != hoverRect {
                hoverRect = hover
                needsDisplay = true
            }
        }
        updateCursor(at: p)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        if (!toolbar.isHidden && toolbar.frame.contains(p)) || modeSwitch.frame.contains(p) {
            NSCursor.arrow.set()
            return
        }
        guard let sel = selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = handle(at: p) {
            (handle.h == 0 ? NSCursor.resizeUpDown : handle.v == 0 ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
        } else if sel.contains(p) {
            if let tool { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set() } else { NSCursor.openHand.set() }
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        session?.focus(self)
        commitText()
        guard let sel = selection else {
            drag = .creating(p)
            return
        }
        if event.clickCount == 2 && tool == nil && sel.contains(p) {
            session?.finish(primaryAction, from: self)
            return
        }
        if let handle = handle(at: p) {
            drag = .resizing(handle, sel)
            return
        }
        guard sel.contains(p) else { return }
        if let tool {
            switch tool {
            case .text:
                beginText(at: p)
            case .number:
                let next = marks.filter { $0.tool == .number }.count + 1
                marks.append(SnipMark(tool: .number, color: color, size: size, start: p, end: p, number: next))
                syncToolbar()
                needsDisplay = true
            default:
                drawing = SnipMark(tool: tool, color: color, size: size, start: p, end: p, points: [p])
                drag = .marking
            }
        } else {
            drag = .moving(p, sel)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .creating(let start):
            selection = Self.rect(from: start, to: p).intersection(bounds).snapped
            hoverRect = nil
        case .moving(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = max(0, min(r.minX, bounds.width - r.width))
            r.origin.y = max(0, min(r.minY, bounds.height - r.height))
            selection = r.snapped
        case .resizing(let handle, let original):
            selection = handle.resize(original, to: p).intersection(bounds).snapped
        case .marking:
            guard var mark = drawing else { return }
            mark.end = p
            if mark.tool == .pen { mark.points.append(p) }
            if mark.tool == .mosaic { mark.mosaic = pixelate(mark.rect) }
            drawing = mark
        }
        layoutToolbar()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Cleared first: the toolbar stays hidden while an area is being drawn.
        let ended = drag
        drag = .none
        switch ended {
        case .creating:
            // A click without a drag takes the window under the pointer, or
            // the whole screen.
            if selection.map({ $0.width < 4 || $0.height < 4 }) ?? true {
                selection = (hoverRect ?? bounds).snapped
            }
            hoverRect = nil
            layoutToolbar()
        case .marking:
            if let mark = drawing, mark.isMeaningful { marks.append(mark) }
            drawing = nil
            syncToolbar()
        default:
            break
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    /// Right click steps back: from an area to picking again, then out.
    override func rightMouseDown(with event: NSEvent) {
        if selection != nil {
            reset()
            pointerMoved(to: convert(event.locationInWindow, from: nil))
        } else {
            session?.finish(.cancel, from: self)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: // Escape
            session?.finish(.cancel, from: self)
        case 36, 76: // Return, Enter
            if selection != nil { session?.finish(primaryAction, from: self) }
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: -step)
        case 126: nudge(dx: 0, dy: step)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if command && key == "z" {
                undo()
            } else if command && key == "c" && selection != nil && mode == .screenshot {
                session?.finish(.done, from: self)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// The arrow keys move the area a point at a time, ten with Shift.
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard var r = selection else { return }
        r.origin.x = max(0, min(r.minX + dx, bounds.width - r.width))
        r.origin.y = max(0, min(r.minY + dy, bounds.height - r.height))
        selection = r
        layoutToolbar()
        needsDisplay = true
    }

    // MARK: Tools

    private func choose(_ chosen: SnipTool) {
        commitText()
        tool = tool == chosen ? nil : chosen
        syncToolbar()
    }

    private func undo() {
        commitText()
        guard !marks.isEmpty else { return }
        marks.removeLast()
        syncToolbar()
        needsDisplay = true
    }

    private func syncToolbar() {
        toolbar.update(mode: mode, audio: session?.recordAudio ?? false,
                       tool: tool, color: color, size: size, canUndo: !marks.isEmpty)
        layoutToolbar()
    }

    /// Under the area, aligned to its right edge; above it when there is no
    /// room below, and inside it when there is none above either.
    private func layoutToolbar() {
        guard let sel = selection else {
            toolbar.isHidden = true
            return
        }
        if case .creating = drag {
            toolbar.isHidden = true
            return
        }
        let size = toolbar.preferredSize
        var x = sel.maxX - size.width
        x = max(4, min(x, bounds.width - size.width - 4))
        var y = sel.minY - 8 - size.height
        if y < 4 {
            y = sel.maxY + 8
            if y + size.height > bounds.height - 4 { y = sel.minY + 8 }
        }
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        toolbar.isHidden = false
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        let font = NSFont.systemFont(ofSize: SnipMark.fontSize(size), weight: .semibold)
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        textOrigin = p
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        field.frame = CGRect(x: p.x - 2, y: p.y - height, width: 60, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let s = NSAttributedString(string: field.stringValue,
                                   attributes: SnipMark.textAttributes(color: color, size: size)).size()
        let height = max(field.frame.height, ceil(s.height) + 4)
        field.frame = CGRect(x: field.frame.minX, y: textOrigin.y - height,
                             width: max(60, ceil(s.width) + 16), height: height)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    /// Return or Escape ends the text; Option-Return starts a new line.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        let textColor = field.textColor ?? color
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        let mark = SnipMark(tool: .text, color: textColor, size: size, start: textOrigin, end: textOrigin, text: text)
        if mark.isMeaningful {
            marks.append(mark)
            syncToolbar()
        }
        needsDisplay = true
    }

    // MARK: Pixels

    /// A view rectangle in the frozen image's pixels, whose origin is at the top.
    private func pixelRect(_ r: CGRect) -> CGRect {
        let s = scale
        return CGRect(x: r.minX * s, y: (bounds.height - r.maxY) * s, width: r.width * s, height: r.height * s).integral
    }

    private func pixelate(_ rect: CGRect) -> CGImage? {
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1, let crop = image.cropping(to: pixelRect(r)) else { return nil }
        let block = max(6, 9 * scale)
        let w = max(1, Int(ceil(CGFloat(crop.width) / block)))
        let h = max(1, Int(ceil(CGFloat(crop.height) / block)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The area with its marks, at the screen's full resolution.
    func render() -> CGImage? {
        commitText()
        guard let sel = selection else { return nil }
        let px = pixelRect(sel)
        let w = Int(px.width), h = Int(px.height)
        guard w > 0, h > 0 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let crop = image.cropping(to: px) {
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: CGFloat(w) / sel.width, y: CGFloat(h) / sel.height)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for mark in marks { mark.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Handles

    private func handle(at p: CGPoint) -> Handle? {
        guard let sel = selection else { return nil }
        if let corner = Handle.all.first(where: { hypot($0.point(in: sel).x - p.x, $0.point(in: sel).y - p.y) <= 7 }) {
            return corner
        }
        // Anywhere along an edge works too, not only its middle dot.
        let near: CGFloat = 4
        let insideX = p.x > sel.minX && p.x < sel.maxX, insideY = p.y > sel.minY && p.y < sel.maxY
        if insideY && abs(p.x - sel.minX) <= near { return Handle(h: -1, v: 0) }
        if insideY && abs(p.x - sel.maxX) <= near { return Handle(h: 1, v: 0) }
        if insideX && abs(p.y - sel.minY) <= near { return Handle(h: 0, v: -1) }
        if insideX && abs(p.y - sel.maxY) <= near { return Handle(h: 0, v: 1) }
        return nil
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// One of the eight handles: -1, 0 or 1 for the left, middle or right, and
/// the bottom, middle or top.
private struct Handle: Equatable {
    let h: Int
    let v: Int

    static let all = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)].map { Handle(h: $0.0, v: $0.1) }

    func point(in r: CGRect) -> CGPoint {
        CGPoint(x: h < 0 ? r.minX : h > 0 ? r.maxX : r.midX,
                y: v < 0 ? r.minY : v > 0 ? r.maxY : r.midY)
    }

    /// Moves this handle's edges to the pointer. Dragging past the opposite
    /// edge flips the area instead of collapsing it.
    func resize(_ r: CGRect, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if h < 0 { minX = p.x } else if h > 0 { maxX = p.x }
        if v < 0 { minY = p.y } else if v > 0 { maxY = p.y }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}

private extension CGRect {
    /// Whole points, so the capture lines up with the screen's pixels.
    var snapped: CGRect {
        guard !isNull else { return .zero }
        let x = minX.rounded(), y = minY.rounded()
        return CGRect(x: x, y: y, width: (maxX.rounded() - x), height: (maxY.rounded() - y))
    }
}
