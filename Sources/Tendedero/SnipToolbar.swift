import AppKit

/// The dark bar under the area: the drawing tools, undo, and what to do with
/// the capture. With a tool chosen, a second bar offers colors and sizes.
@MainActor
final class SnipToolbar: NSView {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.23, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .white,
        .black,
    ]

    var onTool: (SnipTool) -> Void = { _ in }
    var onColor: (NSColor) -> Void = { _ in }
    var onSize: (Int) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onAction: (SnipAction) -> Void = { _ in }
    var onAudio: () -> Void = {}

    private let mainBar = SnipBar()
    private let styleBar = SnipBar()
    /// In record mode, in place of the main bar: sound, cancel, start.
    private let recordBar = SnipBar()
    private var audioButton: BarButton!
    private var mode = SnipMode.screenshot
    private var toolButtons: [(SnipTool, BarButton)] = []
    private var undoButton: BarButton!
    private var swatches: [Swatch] = []
    private var sizeDots: [SizeDot] = []

    private static let button: CGFloat = 32
    private static let pad: CGFloat = 5
    private static let separator: CGFloat = 13
    private static let gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(mainBar)
        addSubview(styleBar)
        addSubview(recordBar)
        build()
        buildRecordBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A click between the buttons stays here, never reaching the area below.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    private func build() {
        let tools: [(SnipTool, String, String)] = [
            (.rect, "rectangle", L("Rectangle", "Rectángulo")),
            (.ellipse, "circle", L("Ellipse", "Elipse")),
            (.line, "line.diagonal", L("Line", "Línea")),
            (.arrow, "arrow.up.right", L("Arrow", "Flecha")),
            (.pen, "pencil.tip", L("Pen", "Lápiz")),
            (.text, "textformat", L("Text", "Texto")),
            (.mosaic, "checkerboard.rectangle", L("Mosaic", "Mosaico")),
            (.number, "1.circle", L("Number", "Número")),
        ]
        var x = Self.pad
        for (tool, symbol, tip) in tools {
            let b = BarButton(symbol: symbol, tip: tip) { [weak self] in self?.onTool(tool) }
            place(b, at: &x)
            toolButtons.append((tool, b))
        }
        x += Self.separator
        undoButton = BarButton(symbol: "arrow.uturn.backward", tip: L("Undo", "Deshacer")) { [weak self] in self?.onUndo() }
        place(undoButton, at: &x)
        x += Self.separator
        let actions: [(SnipAction, String, String, NSColor)] = [
            (.pin, "pin", L("Pin to screen", "Fijar en la pantalla"), .white),
            (.save, "square.and.arrow.down", L("Save as…", "Guardar como…"), .white),
            (.cancel, "xmark", L("Cancel", "Cancelar"), NSColor(srgbRed: 1, green: 0.33, blue: 0.3, alpha: 1)),
            (.done, "checkmark", L("Done", "Hecho"), NSColor(srgbRed: 0.3, green: 0.85, blue: 0.4, alpha: 1)),
        ]
        for (action, symbol, tip, tint) in actions {
            let b = BarButton(symbol: symbol, tip: tip, tint: tint) { [weak self] in self?.onAction(action) }
            place(b, at: &x)
        }
        mainBar.frame = CGRect(x: 0, y: 0, width: x + Self.pad, height: Self.button + Self.pad * 2)

        var sx = Self.pad + 4
        for color in Self.colors {
            let swatch = Swatch(color: color) { [weak self] in self?.onColor(color) }
            swatch.frame = CGRect(x: sx, y: Self.pad + 6, width: 20, height: 20)
            styleBar.addSubview(swatch)
            swatches.append(swatch)
            sx += 26
        }
        sx += 8
        for size in 0..<3 {
            let dot = SizeDot(size: size) { [weak self] in self?.onSize(size) }
            dot.frame = CGRect(x: sx, y: Self.pad + 2, width: 28, height: 28)
            styleBar.addSubview(dot)
            sizeDots.append(dot)
            sx += 30
        }
        styleBar.frame = CGRect(x: 0, y: mainBar.frame.maxY + Self.gap,
                                width: sx + Self.pad, height: Self.button + Self.pad * 2)
    }

    private func buildRecordBar() {
        var x = Self.pad
        audioButton = BarButton(symbol: "speaker.wave.2", tip: L("Record the system's sound", "Grabar el sonido del sistema")) {
            [weak self] in self?.onAudio()
        }
        place(audioButton, at: &x, in: recordBar)
        x += Self.separator
        let cancel = BarButton(symbol: "xmark", tip: L("Cancel", "Cancelar"),
                               tint: NSColor(srgbRed: 1, green: 0.33, blue: 0.3, alpha: 1)) { [weak self] in
            self?.onAction(.cancel)
        }
        place(cancel, at: &x, in: recordBar)

        let start = StartButton(title: L("Start recording", "Grabar")) { [weak self] in self?.onAction(.record) }
        start.frame = CGRect(x: x + 4, y: Self.pad, width: start.fittingWidth, height: Self.button)
        recordBar.addSubview(start)
        x = start.frame.maxX
        recordBar.frame = CGRect(x: 0, y: 0, width: x + Self.pad, height: Self.button + Self.pad * 2)
    }

    private func place(_ b: BarButton, at x: inout CGFloat, in bar: NSView? = nil) {
        b.frame = CGRect(x: x, y: Self.pad, width: Self.button, height: Self.button)
        (bar ?? mainBar).addSubview(b)
        x += Self.button + 2
    }

    var preferredSize: CGSize {
        if mode == .record { return recordBar.frame.size }
        let height = styleBar.isHidden ? mainBar.frame.height : styleBar.frame.maxY
        return CGSize(width: mainBar.frame.width, height: height)
    }

    func update(mode: SnipMode, audio: Bool, tool: SnipTool?, color: NSColor, size: Int, canUndo: Bool) {
        self.mode = mode
        mainBar.isHidden = mode == .record
        recordBar.isHidden = mode != .record
        audioButton.image = NSImage(systemSymbolName: audio ? "speaker.wave.2.fill" : "speaker.slash",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        audioButton.isOn = audio
        audioButton.toolTip = audio ? L("System sound on", "Sonido del sistema activado")
                                    : L("System sound off", "Sonido del sistema desactivado")
        for (t, b) in toolButtons { b.isOn = t == tool }
        undoButton.isEnabled = canUndo
        styleBar.isHidden = tool == nil || mode == .record
        for s in swatches { s.isOn = s.color == color }
        for d in sizeDots { d.isOn = d.size == size }
        // The style bar sits right under the main bar, at its right end.
        styleBar.frame.origin.x = mainBar.frame.width - styleBar.frame.width
    }
}

/// The red pill that starts a recording.
private final class StartButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.25, blue: 0.23, alpha: 1).cgColor
        layer?.cornerRadius = 7
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        imagePosition = .imageLeading
        contentTintColor = .white
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + 52 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }
}

/// "Screenshot | Record" at the top of every screen, as in Feishu.
@MainActor
final class ModeSwitch: NSView {
    var onChange: (SnipMode) -> Void = { _ in }
    var mode = SnipMode.screenshot { didSet { refresh() } }

    private let shot: ModeSegment
    private let record: ModeSegment

    init() {
        shot = ModeSegment(symbol: "camera.viewfinder", title: L("Screenshot", "Captura"))
        record = ModeSegment(symbol: "record.circle", title: L("Record", "Grabar"))
        let width = max(shot.fittingWidth, record.fittingWidth)
        super.init(frame: CGRect(x: 0, y: 0, width: width * 2 + 8, height: 38))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.94).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
        shot.frame = CGRect(x: 4, y: 4, width: width, height: 30)
        record.frame = CGRect(x: 4 + width, y: 4, width: width, height: 30)
        shot.handler = { [weak self] in self?.choose(.screenshot) }
        record.handler = { [weak self] in self?.choose(.record) }
        addSubview(shot)
        addSubview(record)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    private func choose(_ mode: SnipMode) {
        guard mode != self.mode else { return }
        onChange(mode)
    }

    private func refresh() {
        shot.isOn = mode == .screenshot
        record.isOn = mode == .record
    }
}

private final class ModeSegment: NSButton {
    var handler: () -> Void = {}
    var isOn = false { didSet { layer?.backgroundColor = isOn ? NSColor(white: 1, alpha: 0.16).cgColor : nil } }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        imagePosition = .imageLeading
        contentTintColor = .white
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + 48 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }
}

/// A rounded dark plate.
private final class SnipBar: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.94).cgColor
        layer?.cornerRadius = 9
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

private final class BarButton: NSButton {
    private let handler: () -> Void
    private let tint: NSColor

    var isOn = false { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }

    init(symbol: String, tip: String, tint: NSColor = .white, handler: @escaping () -> Void) {
        self.handler = handler
        self.tint = tint
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        image = (NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tip))?
            .withSymbolConfiguration(config)
        toolTip = tip
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 6
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }

    private func refresh() {
        contentTintColor = isOn ? NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: 1)
            : tint.withAlphaComponent(isEnabled ? 1 : 0.35)
        layer?.backgroundColor = isOn ? NSColor(white: 1, alpha: 0.14).cgColor : nil
    }
}

private final class Swatch: NSView {
    let color: NSColor
    private let handler: () -> Void
    var isOn = false { didSet { needsDisplay = true } }

    init(color: NSColor, handler: @escaping () -> Void) {
        self.color = color
        self.handler = handler
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { handler() }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: isOn ? 4 : 3, dy: isOn ? 4 : 3)
        color.setFill()
        NSBezierPath(ovalIn: inner).fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        let edge = NSBezierPath(ovalIn: inner)
        edge.lineWidth = 0.5
        edge.stroke()
        if isOn {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

private final class SizeDot: NSView {
    let size: Int
    private let handler: () -> Void
    var isOn = false { didSet { needsDisplay = true } }

    init(size: Int, handler: @escaping () -> Void) {
        self.size = size
        self.handler = handler
        super.init(frame: .zero)
        toolTip = [L("Thin", "Fino"), L("Medium", "Medio"), L("Thick", "Grueso")][size]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { handler() }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor(white: 1, alpha: 0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let d: CGFloat = [5, 9, 13][size]
        (isOn ? NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
    }
}
