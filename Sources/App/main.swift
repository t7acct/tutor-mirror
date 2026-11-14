import AppKit
import Combine
import os

// MARK: - Mirror window

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    let manager: AirPlayManager
    private let videoView: MetalVideoView
    private let statusLabel = NSTextField(labelWithString: "")
    private let lagMeter = LagMeterPanel()
    private let badge = BadgePanel()
    private let blankOverlay = NSView()
    private(set) var isBlank = false
    /// Called whenever freeze/blank changes (menu bar icon).
    var onModeChange: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isMirroring = false
    private var statsLogTimer: Timer?
    private let lagLog = Logger(subsystem: "local.tutormirror", category: "Lag")

    init(manager: AirPlayManager) {
        self.manager = manager
        guard let view = MetalVideoView(videoFrame: NSRect(x: 0, y: 0, width: 1024, height: 768)) else {
            fatalError("Metal is not available on this Mac")
        }
        self.videoView = view

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Settings.receiverName
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentAspectRatio = NSSize(width: 4, height: 3)
        window.setFrameAutosaveName("TutorMirrorWindow")
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container

        videoView.autoresizingMask = [.width, .height]
        videoView.frame = container.bounds
        container.addSubview(videoView)

        statusLabel.font = .systemFont(ofSize: 20, weight: .medium)
        statusLabel.textColor = .init(white: 0.85, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        // "Blank" screen: what the student sees while you set something up.
        blankOverlay.wantsLayer = true
        blankOverlay.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).cgColor
        blankOverlay.autoresizingMask = [.width, .height]
        blankOverlay.frame = container.bounds
        blankOverlay.isHidden = true
        let blankLabel = NSTextField(labelWithString: "One moment…")
        blankLabel.font = .systemFont(ofSize: 34, weight: .medium)
        blankLabel.textColor = .init(white: 0.85, alpha: 1)
        blankLabel.translatesAutoresizingMaskIntoConstraints = false
        blankOverlay.addSubview(blankLabel)
        NSLayoutConstraint.activate([
            blankLabel.centerXAnchor.constraint(equalTo: blankOverlay.centerXAnchor),
            blankLabel.centerYAnchor.constraint(equalTo: blankOverlay.centerYAnchor),
        ])
        container.addSubview(blankOverlay)

        manager.videoDecoder.sink = videoView
        videoView.onVideoSizeChange = { [weak self] size in self?.videoSizeChanged(size) }

        manager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)

        // Write the lag numbers to the system log every 2 s while mirroring, so
        // a session can be reviewed afterwards:
        //   log show --last 10m --predicate 'subsystem == "local.tutormirror" AND category == "Lag"'
        statsLogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMirroring else { return }
                let s = LatencyStats.shared.summary()
                func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
                let line = "\(s.width)x\(s.height) in=\(s.receivedFPS)fps shown=\(s.shownFPS) skipped=\(s.skipped)"
                    + " wifiRTT=\(ClockSync.shared.roundTrip.map { ms($0) } ?? "-")/worst \(ClockSync.shared.worstRoundTrip.map { ms($0) } ?? "-")"
                    + " decode=\(ms(s.decode.avg))/p95 \(ms(s.decode.p95))"
                    + " display=\(ms(s.display.avg))/p95 \(ms(s.display.p95))"
                    + " mac=\(ms(s.macSide.avg))/p95 \(ms(s.macSide.p95))"
                    + " gap=\(ms(s.worstGap)) gapIdle=\(ms(s.worstGapSender))"
                    + " netExtra=\(ms(s.netExtra.avg))/p95 \(ms(s.netExtra.p95))"
                self.lagLog.notice("\(line, privacy: .public)")
            }
        }

        if window.frame.origin == .zero { window.center() }
        window.addChildWindow(lagMeter, ordered: .above)
        setLagMeterVisible(Settings.showLagMeter)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func stateChanged(_ state: AirPlayState) {
        switch state {
        case .idle:
            isMirroring = false
            statusLabel.stringValue = "Waiting for iPad\n\nOn the iPad: Control Center → Screen Mirroring → \(Settings.receiverName)"
        case .connecting(let name):
            isMirroring = false
            statusLabel.stringValue = "Connecting to \(name)…"
        case .mirroring:
            isMirroring = true
            statusLabel.stringValue = ""
        case .error(let message):
            isMirroring = false
            statusLabel.stringValue = message
        }
        updateStatusLabel()
    }

    private func updateStatusLabel() {
        // While frozen, keep the frozen picture clean even if the iPad drops off.
        statusLabel.isHidden = isMirroring || videoView.isFrozen
    }

    // MARK: Freeze / blank

    var isFrozen: Bool { videoView.isFrozen }

    func toggleFreeze() { setFrozen(!videoView.isFrozen) }

    func setFrozen(_ frozen: Bool) {
        videoView.setFrozen(frozen)
        updateStatusLabel()
        updateBadge()
    }

    func toggleBlank() {
        isBlank.toggle()
        blankOverlay.isHidden = !isBlank
        updateBadge()
    }

    private func updateBadge() {
        guard let window else { return }
        switch (isFrozen, isBlank) {
        case (_, true):
            badge.show(text: "BLANK — student sees \"One moment…\"   press B to undo", color: .systemPurple, over: window)
        case (true, false):
            badge.show(text: "❄︎ FROZEN — student sees a still picture   press F to go live", color: .systemBlue, over: window)
        default:
            badge.orderOut(nil)
        }
        onModeChange?()
    }

    /// Lock the window to the stream's shape (e.g. 4:3 landscape, 3:4 portrait)
    /// so there are no black bars.
    private func videoSizeChanged(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        let current = window.contentRect(forFrameRect: window.frame)
        let aspect = size.width / size.height
        // Keep the area roughly the same, change the shape.
        let area = current.width * current.height
        var newH = (area / aspect).squareRoot()
        var newW = newH * aspect
        if let screen = window.screen?.visibleFrame {
            let fit = min(1, screen.width / newW, (screen.height - 40) / newH)
            newW *= fit; newH *= fit
        }
        var rect = NSRect(x: current.midX - newW / 2, y: current.maxY - newH, width: newW, height: newH)
        rect = window.frameRect(forContentRect: rect)
        window.setFrame(rect, display: true, animate: false)
    }

    func setLagMeterVisible(_ visible: Bool) {
        Settings.showLagMeter = visible
        if visible {
            lagMeter.orderFront(nil)
            lagMeter.start()
        } else {
            lagMeter.stop()
            lagMeter.orderOut(nil)
        }
    }

    var lagMeterVisible: Bool { Settings.showLagMeter }

    func windowDidResize(_ notification: Notification) { repositionPanels() }
    func windowDidMove(_ notification: Notification) { repositionPanels() }
    func windowDidMiniaturize(_ notification: Notification) { badge.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { updateBadge() }

    private func repositionPanels() {
        lagMeter.reposition()
        if badge.isVisible, let window { badge.reposition(over: window) }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let manager = AirPlayManager()
    var windowController: MirrorWindowController!
    private var selfTest: SelfTest?
    private var keyMonitor: Any?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        windowController = MirrorWindowController(manager: manager)
        windowController.showWindow(nil)
        windowController.onModeChange = { [weak self] in self?.updateStatusItem() }

        // Single-key shortcuts while the TutorMirror window is in front:
        // F = freeze / go live, B = blank / unblank. (Only in this app, so
        // you can still type F and B everywhere else.)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty, event.window === self.windowController.window,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "f": self.windowController.toggleFreeze(); return nil
            case "b": self.windowController.toggleBlank(); return nil
            default: return event
            }
        }
        setUpStatusItem()
        if ProcessInfo.processInfo.environment["TUTORMIRROR_SELFTEST"] != nil {
            manager.state = .mirroring("Self-test")
            // Keep the test window on top: a covered window is never put on
            // screen, so the display timing would read as zero.
            windowController.window?.level = .floating
            let now = UInt64(NTPTime.nowSeconds) << 32
            ClockSync.shared.addSample(t1: now, t2: now, t3: now, t4: now)
            selfTest = SelfTest(decoder: manager.videoDecoder)
            selfTest?.start()
            if ProcessInfo.processInfo.environment["TUTORMIRROR_SELFTEST"] == "freeze" {
                // Scripted freeze test: 3s freeze, 6s blank, 8s unblank, 10s unfreeze.
                let wc = windowController!
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("TEST freeze"); fflush(stdout); wc.setFrozen(true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { print("TEST blank"); fflush(stdout); wc.toggleBlank() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("TEST unblank"); fflush(stdout); wc.toggleBlank() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("TEST live"); fflush(stdout); wc.setFrozen(false) }
            }
        } else {
            manager.start()
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { manager.stop() }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TutorMirror", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TutorMirror", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TutorMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let freeze = NSMenuItem(title: "Freeze Picture", action: #selector(toggleFreeze(_:)), keyEquivalent: "")
        freeze.target = self
        viewMenu.addItem(freeze)
        let blank = NSMenuItem(title: "Blank Screen", action: #selector(toggleBlank(_:)), keyEquivalent: "")
        blank.target = self
        viewMenu.addItem(blank)
        viewMenu.addItem(.separator())
        let lag = NSMenuItem(title: "Show Lag Meter", action: #selector(toggleLagMeter(_:)), keyEquivalent: "l")
        lag.target = self
        viewMenu.addItem(lag)
        let audio = NSMenuItem(title: "Play iPad Audio", action: #selector(toggleAudio(_:)), keyEquivalent: "")
        audio.target = self
        viewMenu.addItem(audio)
        viewMenu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename Receiver…", action: #selector(renameReceiver(_:)), keyEquivalent: "")
        rename.target = self
        viewMenu.addItem(rename)
        let restart = NSMenuItem(title: "Restart Receiver", action: #selector(restartReceiver(_:)), keyEquivalent: "r")
        restart.target = self
        viewMenu.addItem(restart)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc func toggleFreeze(_ sender: Any?) { windowController.toggleFreeze() }
    @objc func toggleBlank(_ sender: Any?) { windowController.toggleBlank() }
    @objc func showMirrorWindow(_ sender: Any?) {
        windowController.showWindow(nil)
        NSApp.activate()
    }

    // MARK: Menu bar icon (visible even when Zoom is in front)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let f = NSMenuItem(title: "Freeze Picture", action: #selector(toggleFreeze(_:)), keyEquivalent: "")
        f.target = self
        menu.addItem(f)
        let b = NSMenuItem(title: "Blank Screen", action: #selector(toggleBlank(_:)), keyEquivalent: "")
        b.target = self
        menu.addItem(b)
        menu.addItem(.separator())
        let w = NSMenuItem(title: "Show Mirror Window", action: #selector(showMirrorWindow(_:)), keyEquivalent: "")
        w.target = self
        menu.addItem(w)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TutorMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let frozen = windowController.isFrozen, blank = windowController.isBlank
        let symbol = blank ? "rectangle.slash" : frozen ? "snowflake" : "ipad.landscape"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TutorMirror")
        button.title = blank ? " BLANK" : frozen ? " FROZEN" : ""
        button.contentTintColor = blank ? .systemPurple : frozen ? .systemBlue : nil
    }

    @objc func toggleLagMeter(_ sender: Any?) {
        windowController.setLagMeterVisible(!windowController.lagMeterVisible)
    }

    @objc func toggleAudio(_ sender: Any?) {
        Settings.playAudio.toggle()
        manager.volume = Settings.playAudio ? 1 : 0
    }

    @objc func restartReceiver(_ sender: Any?) { manager.restart() }

    /// The name shown in the iPhone/iPad Screen Mirroring list.
    @objc func renameReceiver(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rename Receiver"
        alert.informativeText = "This is the name your iPad or iPhone shows under Screen Mirroring."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Settings.receiverName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Settings.receiverName = name
        manager.rename(to: name)
        windowController.window?.title = name
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLagMeter(_:)): item.state = windowController?.lagMeterVisible == true ? .on : .off
        case #selector(toggleAudio(_:)): item.state = Settings.playAudio ? .on : .off
        case #selector(toggleFreeze(_:)):
            item.state = windowController?.isFrozen == true ? .on : .off
            item.title = "Freeze Picture   (F)"
        case #selector(toggleBlank(_:)):
            item.state = windowController?.isBlank == true ? .on : .off
            item.title = "Blank Screen   (B)"
        default: break
        }
        return true
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
