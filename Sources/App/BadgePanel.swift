import AppKit

/// A small "FROZEN" / "BLANK" tag that only you can see.
///
/// It's a separate floating window positioned over the top of the mirror
/// window, excluded from screen capture. When you share just the mirror
/// window in Zoom/Teams, the student never sees it.
final class BadgePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let box = NSView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .floating
        sharingType = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        contentView = box

        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    func show(text: String, color: NSColor, over window: NSWindow) {
        label.stringValue = text
        box.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        let size = NSSize(width: label.fittingSize.width + 28, height: 30)
        setContentSize(size)
        reposition(over: window)
        orderFrontRegardless()
    }

    func reposition(over window: NSWindow) {
        let content = window.contentLayoutRect
        let topCenter = window.convertPoint(toScreen: NSPoint(x: content.midX, y: content.maxY - 10))
        setFrameTopLeftPoint(NSPoint(x: topCenter.x - frame.width / 2, y: topCenter.y))
    }
}
