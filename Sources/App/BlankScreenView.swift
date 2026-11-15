import AppKit

/// The holding screen that replaces the iPad picture in the shared window.
final class BlankScreenView: NSView {
    private static let background = NSColor(srgbRed: 0.040, green: 0.044, blue: 0.070, alpha: 1)
    private static let glow = NSGradient(
        starting: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.205, alpha: 1),
        ending: background
    )

    private let icon = NSImageView(image: BlankScreenView.pauseIllustration)
    private let title = NSTextField(labelWithString: "One moment…")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        layerContentsRedrawPolicy = .duringViewResize
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.textColor = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.99, alpha: 1)
        addSubview(icon)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        let scale = min(1.2, max(0.34, min(bounds.width, bounds.height) / 650))
        title.font = .systemFont(ofSize: (36 * scale).rounded(), weight: .medium)
        let titleHeight = title.intrinsicContentSize.height
        let iconSize = Self.pauseIllustration.size
        let iconHeight = (iconSize.height * scale).rounded()
        let iconWidth = (iconSize.width * scale).rounded()
        let spacing = (25 * scale).rounded()
        let groupHeight = titleHeight + spacing + iconHeight
        let bottom = (bounds.midY - groupHeight / 2).rounded()
        title.frame = NSRect(x: bounds.minX, y: bottom, width: bounds.width, height: titleHeight)
        icon.frame = NSRect(x: (bounds.midX - iconWidth / 2).rounded(),
                            y: title.frame.maxY + spacing, width: iconWidth, height: iconHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        dirtyRect.fill()
        let center = NSPoint(x: bounds.midX, y: icon.frame.midY)
        Self.glow?.draw(fromCenter: center, radius: 0, toCenter: center,
                        radius: max(1, min(bounds.width, bounds.height) * 0.6), options: [])
    }

    // Overlapping screens echo the app icon, with a pause mark on the foreground tablet.
    private static let pauseIllustration = NSImage(size: NSSize(width: 124, height: 96), flipped: false) { _ in
        let lavender = NSColor(srgbRed: 0.82, green: 0.78, blue: 1, alpha: 1)
        let rear = NSBezierPath(roundedRect: NSRect(x: 29, y: 24, width: 92, height: 69), xRadius: 15, yRadius: 15)
        lavender.withAlphaComponent(0.09).setFill()
        rear.fill()
        lavender.withAlphaComponent(0.34).setStroke()
        rear.lineWidth = 1.5
        rear.stroke()

        let front = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 100, height: 73), xRadius: 16, yRadius: 16)
        let top = NSColor(srgbRed: 0.22, green: 0.23, blue: 0.41, alpha: 1)
        let bottom = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.22, alpha: 1)
        bottom.setFill()
        front.fill()
        NSGradient(starting: bottom, ending: top)?.draw(in: front, angle: 90)
        lavender.withAlphaComponent(0.72).setStroke()
        front.lineWidth = 1.5
        front.stroke()

        lavender.setFill()
        for x: CGFloat in [41, 57] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 26, width: 8, height: 27), xRadius: 4, yRadius: 4).fill()
        }
        return true
    }
}
