import AppKit

/// Drawing on top of the mirror from the Mac: pen, highlighter, arrows and
/// boxes. The student sees these (they're drawn in the mirror window). The
/// toolbar to pick them is a separate window only you see.
enum DrawTool: Int, CaseIterable {
    case pen, highlighter, arrow, box

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        case .box: return "Box"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        }
    }
    /// Key that picks this tool while drawing.
    var key: String {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .arrow: return "a"
        case .box: return "r"
        }
    }
}

struct Stroke {
    var tool: DrawTool
    var color: NSColor
    /// Points as fractions of the picture (0…1, top-left origin), so drawings
    /// stay put when the window is resized and scale into snapshots.
    var points: [CGPoint]
}

/// Sits over the video. Handles drawing in draw mode, and zoom / pan
/// (pinch, ⌘-scroll, two-finger scroll, double-click to reset) otherwise.
final class AnnotationView: NSView {
    static let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .black]

    private(set) var strokes: [Stroke] = []
    private var current: Stroke?

    var drawing = false {
        didSet {
            if !drawing, current != nil { current = nil; needsDisplay = true }   // stopped mid-stroke
            window?.invalidateCursorRects(for: self)
            onChange?()
        }
    }
    var tool: DrawTool = .pen { didSet { onChange?() } }
    var color: NSColor = .systemRed { didSet { onChange?() } }

    /// Where the picture sits in this view (aspect-fit area), from the video view.
    var contentRectProvider: () -> CGRect = { .zero }
    var onZoom: ((_ factor: Double, _ around: CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onResetZoom: (() -> Void)?
    var isZoomed: () -> Bool = { false }
    /// Tool, colour or drawing mode changed (toolbar refresh).
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { drawing }

    // MARK: Editing

    func add(_ stroke: Stroke) {
        strokes.append(stroke)
        needsDisplay = true
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    func clear() {
        strokes.removeAll()
        current = nil
        needsDisplay = true
    }

    // MARK: Coordinates

    private var content: CGRect {
        // contentRectProvider is in the video view's (unflipped) coordinates.
        let r = contentRectProvider()
        return CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let c = content
        guard c.width > 0, c.height > 0 else { return .zero }
        return CGPoint(x: min(max((p.x - c.minX) / c.width, 0), 1), y: min(max((p.y - c.minY) / c.height, 0), 1))
    }

    // MARK: Mouse

    override func resetCursorRects() {
        if drawing { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard drawing else {
            if event.clickCount == 2 { onResetZoom?() }
            return
        }
        let p = normalized(event)
        current = Stroke(tool: tool, color: color, points: [p, p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing else {
            // Drag to move around while zoomed in.
            guard isZoomed() else { return }
            let c = content
            guard c.width > 0 else { return }
            onPan?(CGSize(width: event.deltaX / c.width, height: event.deltaY / c.height))
            return
        }
        guard var s = current else { return }
        let p = normalized(event)
        switch s.tool {
        case .pen, .highlighter: s.points.append(p)
        case .arrow, .box: s.points[1] = p
        }
        current = s
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drawing, let s = current else { return }
        current = nil
        strokes.append(s)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, normalized(event))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-scroll zooms (for a mouse wheel).
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
            onZoom?(exp(dy), normalized(event))
        } else if isZoomed() {
            let c = content
            guard c.width > 0 else { return }
            onPan?(CGSize(width: event.scrollingDeltaX / c.width, height: event.scrollingDeltaY / c.height))
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = content
        for s in strokes + (current.map { [$0] } ?? []) {
            Self.render(s, in: ctx, rect: c)
        }
    }

    /// Draws one stroke into `rect` (top-left origin). Also used for snapshots.
    static func render(_ s: Stroke, in ctx: CGContext, rect: CGRect) {
        guard let first = s.points.first else { return }
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
        let base = max(2, rect.height * 0.004)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch s.tool {
        case .pen:
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(base)
        case .highlighter:
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(base * 6)
            ctx.setLineCap(.butt)
        case .arrow, .box:
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(base * 1.2)
        }
        switch s.tool {
        case .pen, .highlighter:
            ctx.move(to: pt(first))
            for p in s.points.dropFirst() { ctx.addLine(to: pt(p)) }
            ctx.strokePath()
        case .box:
            let a = pt(s.points[0]), b = pt(s.points[1])
            ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
        case .arrow:
            let a = pt(s.points[0]), b = pt(s.points[1])
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 1 else { break }
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = min(len * 0.4, base * 7)
            for side in [-1.0, 1.0] {
                let t = angle + .pi + side * .pi / 7
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x + head * cos(t), y: b.y + head * sin(t)))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The snapshot image with the drawings on top.
    func composite(onto image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flip so (0,0) is the top-left, like the strokes.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for s in strokes { Self.render(s, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h)) }
        return ctx.makeImage()
    }
}

// MARK: - Toolbar (only you see it)

/// Floating toolbar under the mirror window while drawing. Excluded from
/// screen capture, so the student only sees the drawings.
final class DrawToolbarPanel: NSPanel {
    private weak var annotations: AnnotationView?
    private let tools = NSSegmentedControl()
    private var colorButtons: [NSButton] = []

    init(annotations: AnnotationView) {
        self.annotations = annotations
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        contentView = box

        tools.segmentCount = DrawTool.allCases.count
        tools.trackingMode = .selectOne
        for t in DrawTool.allCases {
            tools.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title), forSegment: t.rawValue)
            tools.setToolTip("\(t.title) (\(t.key.uppercased()))", forSegment: t.rawValue)
            tools.setWidth(34, forSegment: t.rawValue)
        }
        tools.target = self
        tools.action = #selector(pickTool(_:))

        let stack = NSStackView(views: [tools])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for (i, color) in AnnotationView.colors.enumerated() {
            let b = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            b.isBordered = false
            b.title = ""
            b.wantsLayer = true
            b.layer?.backgroundColor = color.cgColor
            b.layer?.cornerRadius = 11
            b.tag = i
            b.target = self
            b.action = #selector(pickColor(_:))
            b.toolTip = "Colour"
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        stack.addArrangedSubview(button("arrow.uturn.backward", "Undo (⌫)", #selector(undo)))
        stack.addArrangedSubview(button("trash", "Clear all (X)", #selector(clearAll)))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .texturedRounded
        done.toolTip = "Stop drawing (D or Esc). Drawings stay until you clear them."
        stack.addArrangedSubview(done)

        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        setContentSize(stack.fittingSize)
        refresh()
    }

    func refresh() {
        guard let a = annotations else { return }
        tools.selectedSegment = a.tool.rawValue
        for b in colorButtons {
            let selected = AnnotationView.colors[b.tag] == a.color
            b.layer?.borderWidth = selected ? 3 : 1
            b.layer?.borderColor = (selected ? NSColor.white : NSColor.gray).cgColor
            b.isEnabled = a.tool != .highlighter
            b.alphaValue = a.tool == .highlighter ? 0.35 : 1
        }
    }

    /// Centre along the bottom of the mirror window, just inside it.
    func reposition() {
        guard let parent else { return }
        let content = parent.contentLayoutRect
        let bottom = parent.convertPoint(toScreen: NSPoint(x: content.midX, y: content.minY + 12))
        setFrameOrigin(NSPoint(x: bottom.x - frame.width / 2, y: bottom.y))
    }

    @objc private func pickTool(_ sender: NSSegmentedControl) {
        annotations?.tool = DrawTool(rawValue: sender.selectedSegment) ?? .pen
    }
    @objc private func pickColor(_ sender: NSButton) { annotations?.color = AnnotationView.colors[sender.tag] }
    @objc private func undo() { annotations?.undo() }
    @objc private func clearAll() { annotations?.clear() }
    @objc private func done() { annotations?.drawing = false }
}
