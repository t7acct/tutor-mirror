import AppKit

/// Shown once after updating to 0.4.1 or later (and from Help → What's New):
/// what the direct link is, what the tests showed, and a button to turn it
/// on. Only you see it: it's excluded from screen sharing like the other
/// tutor-only windows.
final class DirectLinkIntroWindow: NSWindow {
    /// The Turn On button. Not called when the link is already on.
    var onTurnOn: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var primaryButton: NSButton!

    /// Show it by itself only to people who updated (new users read about it
    /// in the welcome window), only once, only while the link is off, and
    /// never while an iPad is mirroring or connecting.
    static func shouldOffer(hasSeenWelcome: Bool, seenIntro: Bool, linkOn: Bool, busy: Bool) -> Bool {
        hasSeenWelcome && !seenIntro && !linkOn && !busy
    }

    init(linkOn: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        sharingType = .none
        level = .floating

        let symbol = NSImageView(image: NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        symbol.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Connect straight to your iPad")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "New in \(Settings.appName) 0.4 (beta): the iPad can send the picture straight to this Mac instead of through your router.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 440

        let rows = [
            WelcomeWindow.row("chart.line.downtrend.xyaxis", "What I saw in my tests",
                              "Writing in Goodnotes on an iPad Pro, the Wi-Fi delay per frame went from 22 ms to 2 ms and the hitch about once a second went away. The iPad also sent 60 frames a second instead of 31, and the Mac's normal Wi-Fi didn't get any worse."),
            WelcomeWindow.row("wifi", "How it works",
                              "The iPad sends over AWDL, the peer-to-peer Wi-Fi link AirDrop uses, so the picture crosses the air once instead of twice and skips the router. \(Settings.appName) keeps listening on your normal Wi-Fi too."),
            WelcomeWindow.row("number", "The first time",
                              "The iPad asks for a 4-digit code. It shows on this Mac only, never in screen sharing. After that the iPad connects as usual."),
            WelcomeWindow.row("flask", "Still a beta",
                              "I haven't tried it with a Meet call running or through a whole lesson yet. If it gives you trouble, turn it off in View → Connect Directly to iPad (Beta)."),
        ]
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 16
        rowStack.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let primary: NSButton
        var buttons: [NSView] = []
        if linkOn {
            primary = NSButton(title: "OK", target: self, action: #selector(dismiss))
        } else {
            let later = NSButton(title: "Not Now", target: self, action: #selector(dismiss))
            later.bezelStyle = .rounded
            later.controlSize = .large
            later.keyEquivalent = "\u{1b}"
            buttons.append(later)
            primary = NSButton(title: "Turn On Direct Link", target: self, action: #selector(turnOn))
            primary.toolTip = "\(Settings.appName) reopens to switch."
        }
        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primaryButton = primary
        let bottom = NSStackView(views: [NSView()] + buttons + [primary])
        bottom.distribution = .fill
        bottom.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let footer = NSTextField(labelWithString: linkOn
            ? "It's on. Turn it off any time in View → Connect Directly to iPad (Beta)."
            : "\(Settings.appName) reopens to switch. It's also in View → Connect Directly to iPad (Beta).")
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [symbol, title, subtitle, rowStack, bottom, footer])
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

    @objc private func turnOn() {
        let action = onTurnOn
        close()
        action?()
    }

    @objc private func dismiss() { close() }

    override func close() {
        onClose?()
        onClose = nil
        super.close()
    }
}
