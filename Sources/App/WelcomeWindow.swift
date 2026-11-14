import AppKit

/// Shown the first time TutorMirror opens (and from Help → Welcome to
/// TutorMirror). A one-page guide to getting set up. Only you see it: it's
/// excluded from screen sharing like the other tutor-only windows.
final class WelcomeWindow: NSWindow {
    private let updatesBox = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    var onClose: ((_ autoUpdates: Bool) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        sharingType = .none
        level = .floating

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let title = NSTextField(labelWithString: "Welcome to \(Settings.appName)")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "Mirror your iPad or iPhone to this Mac with very little lag, and share it in your lesson.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 440

        let name = Settings.receiverName
        let rows = [
            Self.row("ipad.landscape", "Connect your iPad",
                     "On the iPad, open Control Center → Screen Mirroring → \(name). Keep both on the same Wi-Fi. If macOS asks to find devices on your local network, click Allow."),
            Self.row("rectangle.inset.filled.and.person.filled", "Share the window, not the screen",
                     "In Meet, Zoom or Teams, share the \(Settings.appName) window. The student then sees only the iPad: the window has no title bar. Drag the picture to move it."),
            Self.row("snowflake", "Freeze or blank it",
                     "Click the mirror window, then press F to hold the picture still while you flip to the answers, or B for a \"One moment…\" screen. Press again to go live."),
            Self.row("pencil.tip.crop.circle", "Draw, zoom, crop and save",
                     "D draws on the picture, pinch or ⌘-scroll zooms in, View → Crop hides the status bar, and ⌘S saves the board to Pictures."),
            Self.row("eye.slash", "Some things are just for you",
                     "Your mouse pointer over the mirror, the FROZEN label, the lag meter (⌘L), the drawing toolbar and this window never show up in screen sharing."),
        ]
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 16

        updatesBox.state = Settings.autoCheckUpdates ? .on : .off
        updatesBox.toolTip = "Looks for a new version on GitHub when the app opens. It never interrupts a lesson."

        let start = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.controlSize = .large

        let footer = NSTextField(labelWithString: "See this again any time from Help → Welcome to \(Settings.appName).")
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .tertiaryLabelColor

        let bottom = NSStackView(views: [updatesBox, NSView(), start])
        bottom.distribution = .fill
        bottom.widthAnchor.constraint(equalToConstant: 480).isActive = true
        rowStack.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let stack = NSStackView(views: [icon, title, subtitle, rowStack, bottom, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(26, after: subtitle)
        stack.setCustomSpacing(26, after: rowStack)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 40, bottom: 24, right: 40)
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.state = .active
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        setContentSize(stack.fittingSize)
        center()
    }

    private static func row(_ symbol: String, _ heading: String, _ text: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let h = NSTextField(labelWithString: heading)
        h.font = .systemFont(ofSize: 13, weight: .semibold)
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 13)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 420
        let texts = NSStackView(views: [h, t])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let row = NSStackView(views: [image, texts])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    @objc private func getStarted() { close() }

    override func close() {
        onClose?(updatesBox.state == .on)
        onClose = nil
        super.close()
    }
}
