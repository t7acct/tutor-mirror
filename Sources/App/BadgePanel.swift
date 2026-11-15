import AppKit

enum MirrorHoldMode: String {
    case frozen = "Frozen"
    case blank = "Blank"

    var symbol: String { self == .frozen ? "pause.fill" : "eye.slash" }
    var title: String { self == .frozen ? "Picture frozen" : "Screen blank" }
    var action: String { self == .frozen ? "Go live" : "Show picture" }
    var key: String { self == .frozen ? "F" : "B" }
    var accent: NSColor {
        self == .frozen
            ? NSColor(srgbRed: 0.62, green: 0.81, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.76, blue: 1, alpha: 1)
    }
}

/// A small status panel that only the tutor sees.
///
/// It's a separate floating window positioned over the top of the mirror
/// window, excluded from screen capture. When you share just the mirror
/// window in Zoom/Teams, the student never sees it.
final class BadgePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let keycap = NSView()
    private let iconTile = NSView()
    private let icon = NSImageView()
    private let box = NSView()
    private var mode: MirrorHoldMode?

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

        contentView = box

        for view in [box, iconTile, keycap] { view.wantsLayer = true }
        iconTile.layer?.cornerRadius = 8
        keycap.layer?.cornerRadius = 5
        keycap.layer?.borderWidth = 1
        box.layer?.masksToBounds = true

        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        actionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        actionLabel.textColor = NSColor(srgbRed: 0.73, green: 0.76, blue: 0.83, alpha: 1)
        actionLabel.lineBreakMode = .byTruncatingTail
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyLabel.alignment = .center
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.setAccessibilityElement(false)

        for view in [iconTile, label, actionLabel, keycap] { box.addSubview(view) }
        iconTile.addSubview(icon)
        keycap.addSubview(keyLabel)
    }

    func show(mode: MirrorHoldMode, over window: NSWindow) {
        self.mode = mode
        let accent = mode.accent
        label.stringValue = mode.title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .left
        actionLabel.stringValue = mode.action
        keyLabel.stringValue = mode.key
        keyLabel.setAccessibilityLabel("Press \(mode.key) to \(mode.action.lowercased())")
        keyLabel.textColor = accent
        icon.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
        icon.contentTintColor = accent
        iconTile.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        keycap.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        keycap.layer?.borderColor = accent.withAlphaComponent(0.26).cgColor
        box.layer?.backgroundColor = NSColor(srgbRed: 0.085, green: 0.10, blue: 0.14, alpha: 1).cgColor
        box.layer?.borderColor = accent.withAlphaComponent(0.26).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 13
        present(over: window)
    }

    func show(text: String, color: NSColor, over window: NSWindow) {
        mode = nil
        label.stringValue = text
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.alignment = .center
        box.layer?.borderWidth = 0
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        present(over: window)
    }

    private func present(over window: NSWindow) {
        reposition(over: window)
        orderFrontRegardless()
    }

    func reposition(over window: NSWindow) {
        let content = window.contentLayoutRect
        layoutContents(maxWidth: max(1, content.width - 20))
        let topCenter = window.convertPoint(toScreen: NSPoint(x: content.midX, y: content.maxY - 10))
        setFrameTopLeftPoint(NSPoint(x: topCenter.x - frame.width / 2, y: topCenter.y))
    }

    private func layoutContents(maxWidth: CGFloat) {
        let showsMode = mode != nil
        let titleSize = label.intrinsicContentSize
        let actionSize = actionLabel.intrinsicContentSize
        let padding: CGFloat = showsMode ? 10 : 14
        let iconSpace: CGFloat = 42
        let textEnd = padding + (showsMode ? 38 : 0)
        let textWidth = showsMode ? max(titleSize.width, actionSize.width) + 8 : titleSize.width
        let showsIcon = showsMode && padding + iconSpace + textWidth + textEnd <= maxWidth
        let textStart = padding + (showsIcon ? iconSpace : 0)
        let width = min(maxWidth, ceil(textStart + textWidth + textEnd))
        let height: CGFloat = showsMode ? 52 : 30
        let size = NSSize(width: width, height: height)
        iconTile.isHidden = !showsIcon
        actionLabel.isHidden = !showsMode
        keycap.isHidden = !showsMode
        if box.frame.size != size { setContentSize(size) }

        let lineWidth = max(0, width - textStart - textEnd)
        let titleY = showsMode ? (height + actionSize.height - titleSize.height) / 2 + 1 : (height - titleSize.height) / 2
        label.frame = NSRect(x: textStart, y: floor(titleY), width: lineWidth, height: titleSize.height)
        guard showsMode else { return }

        actionLabel.frame = NSRect(x: textStart, y: label.frame.minY - actionSize.height - 2,
                                   width: lineWidth, height: actionSize.height)
        iconTile.frame = NSRect(x: padding, y: 10, width: 32, height: 32)
        icon.frame = iconTile.bounds.insetBy(dx: 7, dy: 7)
        keycap.frame = NSRect(x: width - padding - 24, y: 14, width: 24, height: 24)
        let keyHeight = keyLabel.intrinsicContentSize.height
        keyLabel.frame = NSRect(x: 0, y: floor((24 - keyHeight) / 2), width: 24, height: keyHeight)
    }
}
