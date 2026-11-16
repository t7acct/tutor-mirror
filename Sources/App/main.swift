import AppKit
import Combine
import os

// MARK: - Mirror window

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    let manager: AirPlayManager
    let videoView: MetalVideoView
    private let statusLabel = NSTextField(labelWithString: "")
    /// Shown under an error (port taken, no Local Network access).
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let lagMeter = LagMeterPanel()
    let badge = BadgePanel()
    let toastBadge = BadgePanel()
    let blankOverlay = BlankScreenView()
    let annotations = AnnotationView()
    /// Hides your mouse pointer from the student while it's over the mirror.
    let pointer: PointerHider
    private(set) lazy var drawToolbar = DrawToolbarPanel(annotations: annotations)
    private(set) var cropPanel: CropPanel?
    private(set) var toast: (text: String, color: NSColor)?
    private var toastTimer: Timer?
    private(set) var isBlank = false
    /// Called whenever freeze/blank changes (menu bar icon).
    var onModeChange: (() -> Void)?
    /// Called when mirroring stops (a good moment to offer an update).
    var onIdle: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isMirroring = false
    private var statsLogTimer: Timer?
    private let lagLog = Logger(subsystem: "local.tutormirror", category: "Lag")
    /// Held while mirroring. During a lesson Meet/Zoom is the front app, and
    /// macOS is otherwise free to nap a background app or delay its work.
    private var mirroringActivity: NSObjectProtocol?

    init(manager: AirPlayManager) {
        self.manager = manager
        guard let view = MetalVideoView(videoFrame: NSRect(x: 0, y: 0, width: 1024, height: 768)) else {
            fatalError("Metal is not available on this Mac")
        }
        self.videoView = view

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The title still names the window in Meet's or Zoom's window list, but
        // nothing of the title bar is drawn: a shared window includes its title
        // bar, and the student should see only the iPad. Close, minimise and
        // full screen are in the menus (⌘W, ⌘M, ⌃⌘F); drag the picture to move it.
        window.title = Settings.receiverName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        // Any shape: the picture keeps its own shape inside, with black bars
        // around it. A window locked to the iPad's shape couldn't fill the
        // screen in full screen or when Rectangle maximised it.
        window.contentMinSize = NSSize(width: 320, height: 180)
        window.setFrameAutosaveName("TutorMirrorWindow")
        pointer = PointerHider(window: window, enabled: Settings.hidePointer)
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

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        // Drawings and zoom / pan handling, over the video. The student sees
        // the drawings; the toolbar to make them is a separate window.
        annotations.autoresizingMask = [.width, .height]
        annotations.frame = container.bounds
        container.addSubview(annotations)
        annotations.contentRectProvider = { [weak self] in self?.videoView.contentRect ?? .zero }
        annotations.onZoom = { [weak self] factor, point in self?.videoView.zoom(by: factor, around: point) }
        annotations.onPan = { [weak self] delta in self?.videoView.pan(by: delta) }
        annotations.onResetZoom = { [weak self] in self?.videoView.resetZoom() }
        annotations.isZoomed = { [weak self] in (self?.videoView.zoomScale ?? 1) > 1 }
        annotations.onChange = { [weak self] in self?.drawingChanged() }
        videoView.onViewportChange = { [weak self] in
            self?.annotations.needsDisplay = true
            self?.updateBadge()
        }
        videoView.setCrop(Settings.crop)

        container.addSubview(retryButton)
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
        ])

        // "Blank" screen: what the student sees while you set something up.
        blankOverlay.autoresizingMask = [.width, .height]
        blankOverlay.frame = container.bounds
        blankOverlay.isHidden = true
        container.addSubview(blankOverlay)

        manager.videoDecoder.sink = videoView
        videoView.onVideoSizeChange = { [weak self] size in self?.videoSizeChanged(size) }

        manager.onRefusedTakeover = { [weak self] name in
            self?.showToast("Kept \(name ?? "another device") from taking over", color: .systemOrange, for: 5)
        }

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
            onIdle?()
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
        if case .error = state { retryButton.isHidden = false } else { retryButton.isHidden = true }
        updateStatusLabel()
        setLatencyCritical(isMirroring)
    }

    @objc private func retry() { manager.restart() }

    private func setLatencyCritical(_ on: Bool) {
        if on, mirroringActivity == nil {
            mirroringActivity = ProcessInfo.processInfo.beginActivity(
                // Also keeps the display awake: you may write on the iPad for a
                // long time without touching the Mac, and a sleeping display
                // would stop the shared window updating for the student.
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "Mirroring the iPad")
        } else if !on, let activity = mirroringActivity {
            ProcessInfo.processInfo.endActivity(activity)
            mirroringActivity = nil
        }
    }

    private func updateStatusLabel() {
        // While frozen, keep the frozen picture clean even if the iPad drops off.
        statusLabel.isHidden = isMirroring || videoView.isFrozen
    }

    // MARK: Freeze / blank

    var isFrozen: Bool { videoView.isFrozen }
    var holdMode: MirrorHoldMode? { isBlank ? .blank : (isFrozen ? .frozen : nil) }

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
        defer { onModeChange?() }
        guard window.isVisible, !window.isMiniaturized else {
            hideBadges()
            return
        }
        let zoom = videoView.zoomScale
        if let holdMode {
            badge.show(mode: holdMode, over: window)
        } else if toast == nil, zoom > 1.01 {
            badge.show(text: String(format: "ZOOMED %.1f×   press 0 to see the whole page", zoom), color: .systemGray, over: window)
        } else {
            badge.orderOut(nil)
        }

        if let toast {
            toastBadge.show(text: toast.text, color: toast.color, over: window, below: badge.isVisible ? badge : nil)
        } else {
            toastBadge.orderOut(nil)
        }
    }

    private func hideBadges() {
        badge.orderOut(nil)
        toastBadge.orderOut(nil)
    }

    /// A short message on the tutor-only badge (e.g. "Snapshot saved").
    func showToast(_ text: String, color: NSColor = .systemGreen, for seconds: TimeInterval = 2.5) {
        toastTimer?.invalidate()
        toast = (text, color)
        updateBadge()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toast = nil
                self?.toastTimer = nil
                self?.updateBadge()
            }
        }
        toastTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Drawing

    var isDrawing: Bool { annotations.drawing }

    func toggleDrawing() { annotations.drawing.toggle() }

    private func drawingChanged() {
        drawToolbar.refresh()
        pointer.drawing = annotations.drawing
        guard let window else { return }
        if annotations.drawing {
            if drawToolbar.parent == nil { window.addChildWindow(drawToolbar, ordered: .above) }
            drawToolbar.reposition()
            drawToolbar.orderFront(nil)
        } else if drawToolbar.parent != nil {
            window.removeChildWindow(drawToolbar)
            drawToolbar.orderOut(nil)
        }
        onModeChange?()
    }

    // MARK: Zoom

    func zoomIn() { videoView.zoom(by: 1.25, around: CGPoint(x: 0.5, y: 0.5)) }
    func zoomOut() { videoView.zoom(by: 0.8, around: CGPoint(x: 0.5, y: 0.5)) }
    func resetZoom() { videoView.resetZoom() }
    var isZoomed: Bool { videoView.zoomScale > 1.01 }

    // MARK: Crop

    func setCrop(_ insets: CropInsets) {
        Settings.crop = insets.clamped
        videoView.setCrop(insets)
        cropPanel?.close()
        cropPanel = nil
    }

    func showCropPanel() {
        if cropPanel == nil {
            let panel = CropPanel(insets: Settings.crop)
            panel.onChange = { [weak self] insets in
                Settings.crop = insets
                self?.videoView.setCrop(insets)
            }
            if let frame = window?.frame {
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX + 12, y: frame.maxY))
            }
            cropPanel = panel
        }
        cropPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: Snapshots

    /// What the student sees right now (cropped, zoomed, with drawings).
    func snapshotImage() -> CGImage? {
        guard !isBlank, let frame = videoView.snapshot() else { return nil }
        return annotations.composite(onto: frame) ?? frame
    }

    static var snapshotsFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("TutorMirror")
    }

    func saveSnapshot() {
        guard let image = snapshotImage() else {
            showToast(isBlank ? "Nothing to save while blank" : "Nothing to save yet", color: .systemOrange)
            return
        }
        let folder = Self.snapshotsFolder
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("TutorMirror \(f.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            showToast("Saved to Pictures › TutorMirror")
        } catch {
            showToast("Couldn't save the snapshot", color: .systemRed)
        }
    }

    func copySnapshot() {
        guard let image = snapshotImage() else {
            showToast("Nothing to copy yet", color: .systemOrange)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: .zero)])
        showToast("Copied the picture")
    }

    /// The picture changed shape: Goodnotes presentation mode starting or
    /// stopping, Split View or Slide Over, a rotation. The window stays exactly
    /// where you, Rectangle or full screen put it, and the picture fits inside
    /// with black bars. (It used to reshape the window, which undid a
    /// maximised or full-screen window every time.)
    private func videoSizeChanged(_ size: CGSize) {
        annotations.needsDisplay = true
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Where the picture is on screen, without the black bars.
    var pictureFrameOnScreen: NSRect? {
        guard let window, videoView.croppedVideoSize.width > 0 else { return nil }
        return window.convertToScreen(videoView.convert(videoView.contentRect, to: nil))
    }

    var canFitWindowToPicture: Bool {
        guard !isFullScreen, let window, let picture = pictureFrameOnScreen else { return false }
        return abs(picture.width - window.frame.width) > 1 || abs(picture.height - window.frame.height) > 1
    }

    /// Trims the black bars: the window shrinks to the picture, which stays the
    /// same size in the same place.
    func fitWindowToPicture() {
        guard canFitWindowToPicture, let window, var rect = pictureFrameOnScreen?.integral else { return }
        let minSize = window.contentMinSize
        if rect.width < minSize.width || rect.height < minSize.height {
            // Too small to trim further: grow around the picture's centre.
            let s = max(minSize.width / rect.width, minSize.height / rect.height)
            rect = NSRect(x: rect.midX - rect.width * s / 2, y: rect.midY - rect.height * s / 2,
                          width: rect.width * s, height: rect.height * s).integral
        }
        // The content view fills the whole frame (no title bar), so the
        // picture's rectangle is the new frame.
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
    func windowDidMiniaturize(_ notification: Notification) { hideBadges() }
    func windowDidDeminiaturize(_ notification: Notification) { updateBadge() }
    // Fill the whole screen in full screen, whatever the picture's shape.
    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize { proposedSize }
    func windowDidEnterFullScreen(_ notification: Notification) { updateBadge(); repositionPanels() }
    func windowDidExitFullScreen(_ notification: Notification) { updateBadge(); repositionPanels() }

    private func repositionPanels() {
        lagMeter.reposition()
        if drawToolbar.parent != nil { drawToolbar.reposition() }
        guard let window else { return }
        if badge.isVisible { badge.reposition(over: window) }
        if toastBadge.isVisible { toastBadge.reposition(over: window, below: badge.isVisible ? badge : nil) }
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
    private(set) var welcome: WelcomeWindow?

    /// Mirroring, or an iPad is connecting: never interrupt with update prompts.
    private var isMirroring: Bool {
        switch manager.state {
        case .mirroring, .connecting: return true
        default: return false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        windowController = MirrorWindowController(manager: manager)
        windowController.showWindow(nil)
        windowController.onModeChange = { [weak self] in self?.updateStatusItem() }
        windowController.onIdle = { Updater.shared.offerPendingIfAppropriate() }

        // Single-key shortcuts while the TutorMirror window is in front (only
        // in this app, so you can still type these letters everywhere else).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        setUpStatusItem()
        let selfTestMode = ProcessInfo.processInfo.environment["TUTORMIRROR_SELFTEST"]
        if selfTestMode == "ui" {
            // Headless check of the windows, crop/zoom shader, snapshots and
            // updater. Shows nothing and never takes focus, so it can run
            // while the real app is in use.
            windowController.window?.alphaValue = 0
            windowController.window?.ignoresMouseEvents = true
            manager.state = .mirroring("Self-test")
            UICheck(app: self).run()
            return
        }
        if let selfTestMode {
            manager.state = .mirroring("Self-test")
            // Keep the test window on top: a covered window is never put on
            // screen, so the display timing would read as zero.
            windowController.window?.level = .floating
            let now = UInt64(NTPTime.nowSeconds) << 32
            ClockSync.shared.addSample(t1: now, t2: now, t3: now, t4: now)
            selfTest = SelfTest(decoder: manager.videoDecoder)
            selfTest?.start()
            if selfTestMode == "freeze" {
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

        Updater.shared.isBusy = { [weak self] in self?.isMirroring ?? false }
        if !Settings.hasSeenWelcome {
            showWelcome(nil)
        } else if selfTestMode == nil {
            Updater.shared.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Updater.shared.offerPendingIfAppropriate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.pointer.stop()
        manager.stop()
    }

    // MARK: Keys

    /// Returns true if the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, event.window === windowController.window,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if event.isARepeat && (key == "f" || key == "b") { return true }
        let wc = windowController!
        if wc.isDrawing {
            switch event.keyCode {
            case 53: wc.annotations.drawing = false; return true          // Esc
            case 51, 117: wc.annotations.undo(); return true               // Delete
            default: break
            }
            if let tool = DrawTool.allCases.first(where: { $0.key == key }) {
                wc.annotations.tool = tool
                return true
            }
        }
        switch key {
        case "f": wc.toggleFreeze()
        case "b": wc.toggleBlank()
        case "d": wc.toggleDrawing()
        case "x": wc.annotations.clear()
        case "=", "+": wc.zoomIn()
        case "-", "_": wc.zoomOut()
        case "0": wc.resetZoom()
        default: return false
        }
        return true
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func buildMenu() {
        let name = Settings.appName
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates(_:))))
        appMenu.addItem(item("Check for Updates Automatically", #selector(toggleAutoUpdates(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Save Snapshot", #selector(saveSnapshot(_:)), "s"))
        fileMenu.addItem(item("Show Snapshots Folder", #selector(showSnapshots(_:))))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        // Standard text editing (rename field) plus copying the picture: ⌘C
        // copies text in a text field, and the mirror picture otherwise.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo Drawing", #selector(undoDrawing(_:)), "z"))
        editMenu.addItem(item("Clear Drawings   (X)", #selector(clearDrawings(_:))))
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Freeze Picture", #selector(toggleFreeze(_:))))
        viewMenu.addItem(item("Blank Screen", #selector(toggleBlank(_:))))
        viewMenu.addItem(item("Draw on Picture", #selector(toggleDrawing(_:))))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom In   (=)", #selector(zoomIn(_:))))
        viewMenu.addItem(item("Zoom Out   (-)", #selector(zoomOut(_:))))
        viewMenu.addItem(item("Whole Page   (0)", #selector(resetZoom(_:))))
        let cropMenu = NSMenu(title: "Crop")
        let noCrop = item("No Crop", #selector(setCropPreset(_:))); noCrop.tag = 0
        let status = item("Hide Status Bar", #selector(setCropPreset(_:))); status.tag = 1
        let toolbar = item("Hide Status Bar and Toolbar", #selector(setCropPreset(_:))); toolbar.tag = 2
        cropMenu.addItem(noCrop); cropMenu.addItem(status); cropMenu.addItem(toolbar)
        cropMenu.addItem(.separator())
        cropMenu.addItem(item("Adjust Crop…", #selector(adjustCrop(_:)), "k"))
        viewMenu.addItem(withTitle: "Crop", action: nil, keyEquivalent: "").submenu = cropMenu
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Hide Pointer from Students", #selector(toggleHidePointer(_:))))
        viewMenu.addItem(item("Show Lag Meter", #selector(toggleLagMeter(_:)), "l"))
        viewMenu.addItem(item("Play iPad Audio", #selector(toggleAudio(_:))))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Rename Receiver…", #selector(renameReceiver(_:))))
        viewMenu.addItem(item("Let Other Devices Take Over", #selector(toggleAllowTakeover(_:))))
        viewMenu.addItem(item("Restart Receiver", #selector(restartReceiver(_:)), "r"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(item("Fit Window to Picture", #selector(fitWindowToPicture(_:))))
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(item("Show Mirror Window", #selector(showMirrorWindow(_:))))
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Welcome to \(name)", #selector(showWelcome(_:))))
        helpMenu.addItem(item("\(name) on GitHub", #selector(openGitHub(_:))))
        helpMenu.addItem(item("Report a Problem…", #selector(reportProblem(_:))))
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    @objc func toggleFreeze(_ sender: Any?) { windowController.toggleFreeze() }
    @objc func toggleBlank(_ sender: Any?) { windowController.toggleBlank() }
    @objc func toggleDrawing(_ sender: Any?) { windowController.toggleDrawing() }
    @objc func undoDrawing(_ sender: Any?) { windowController.annotations.undo() }
    @objc func clearDrawings(_ sender: Any?) { windowController.annotations.clear() }
    @objc func zoomIn(_ sender: Any?) { windowController.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { windowController.zoomOut() }
    @objc func resetZoom(_ sender: Any?) { windowController.resetZoom() }
    @objc func saveSnapshot(_ sender: Any?) { windowController.saveSnapshot() }
    /// ⌘C when no text field has focus: copy the picture.
    @objc func copy(_ sender: Any?) { windowController.copySnapshot() }
    @objc func adjustCrop(_ sender: Any?) { windowController.showCropPanel() }
    @objc func fitWindowToPicture(_ sender: Any?) { windowController.fitWindowToPicture() }

    @objc func setCropPreset(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: windowController.setCrop(.statusBar)
        case 2: windowController.setCrop(.statusBarAndToolbar)
        default: windowController.setCrop(.none)
        }
    }

    @objc func showSnapshots(_ sender: Any?) {
        let folder = MirrorWindowController.snapshotsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc func showMirrorWindow(_ sender: Any?) {
        windowController.showWindow(nil)
        NSApp.activate()
    }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkNow() }
    @objc func toggleAutoUpdates(_ sender: Any?) { Updater.shared.setAutomatic(!Settings.autoCheckUpdates) }
    @objc func openGitHub(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
    @objc func reportProblem(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/issues/new")!) }

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let w = WelcomeWindow()
            w.onClose = { [weak self] autoUpdates in
                let firstRun = !Settings.hasSeenWelcome
                Settings.hasSeenWelcome = true
                let selfTest = ProcessInfo.processInfo.environment["TUTORMIRROR_SELFTEST"] != nil
                // Start checking after the first welcome, or when the box was
                // just ticked; stop if it was just unticked.
                if autoUpdates != Settings.autoCheckUpdates || (firstRun && autoUpdates) {
                    if selfTest { Settings.autoCheckUpdates = autoUpdates } else { Updater.shared.setAutomatic(autoUpdates) }
                }
                self?.welcome = nil
            }
            welcome = w
        }
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Menu bar icon (visible even when Zoom is in front)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(self.item("Freeze Picture", #selector(toggleFreeze(_:))))
        menu.addItem(self.item("Blank Screen", #selector(toggleBlank(_:))))
        menu.addItem(self.item("Draw on Picture", #selector(toggleDrawing(_:))))
        menu.addItem(self.item("Clear Drawings   (X)", #selector(clearDrawings(_:))))
        menu.addItem(.separator())
        menu.addItem(self.item("Save Snapshot", #selector(saveSnapshot(_:))))
        menu.addItem(self.item("Show Mirror Window", #selector(showMirrorWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Settings.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        // Menu bar items show no shortcuts.
        for i in menu.items { i.keyEquivalent = "" }
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let mode = windowController.holdMode
        let symbol = mode?.symbol ?? "ipad.landscape"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Settings.appName)
        var title = mode.map { " " + $0.rawValue.uppercased() } ?? ""
        if Settings.isTestCopy { title += " TEST" }
        button.title = title
        button.contentTintColor = mode.map { $0 == .blank ? .systemPurple : .systemBlue }
    }

    @objc func toggleLagMeter(_ sender: Any?) {
        windowController.setLagMeterVisible(!windowController.lagMeterVisible)
    }

    @objc func toggleAudio(_ sender: Any?) {
        Settings.playAudio.toggle()
        manager.volume = Settings.playAudio ? 1 : 0
    }

    @objc func restartReceiver(_ sender: Any?) { manager.restart() }

    @objc func toggleAllowTakeover(_ sender: Any?) { Settings.allowTakeover.toggle() }

    @objc func toggleHidePointer(_ sender: Any?) {
        Settings.hidePointer.toggle()
        windowController.pointer.enabled = Settings.hidePointer
    }

    /// The name shown in the iPhone/iPad Screen Mirroring list.
    @objc func renameReceiver(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rename Receiver"
        alert.informativeText = "This is the name your iPad or iPhone shows under Screen Mirroring."
        alert.window.sharingType = .none
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Settings.receiverName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Bonjour names are at most 63 bytes; a longer one would fail to advertise.
        while name.utf8.count > 63 { name.removeLast() }
        Settings.receiverName = name
        manager.rename(to: name)
        windowController.window?.title = name
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let wc = windowController
        switch item.action {
        case #selector(toggleLagMeter(_:)): item.state = wc?.lagMeterVisible == true ? .on : .off
        case #selector(toggleAudio(_:)): item.state = Settings.playAudio ? .on : .off
        case #selector(toggleHidePointer(_:)):
            item.state = Settings.hidePointer ? .on : .off
            item.toolTip = "Over the mirror window, students don't see your mouse pointer. You see a stand-in that screen sharing leaves out."
        case #selector(toggleAutoUpdates(_:)): item.state = Settings.autoCheckUpdates ? .on : .off
        case #selector(toggleAllowTakeover(_:)):
            item.state = Settings.allowTakeover ? .on : .off
            item.toolTip = "When off, only the iPad that's mirroring can reconnect until it stops."
        case #selector(toggleFreeze(_:)):
            item.state = wc?.isFrozen == true ? .on : .off
            item.title = "Freeze Picture   (F)"
        case #selector(toggleBlank(_:)):
            item.state = wc?.isBlank == true ? .on : .off
            item.title = "Blank Screen   (B)"
        case #selector(toggleDrawing(_:)):
            item.state = wc?.isDrawing == true ? .on : .off
            item.title = "Draw on Picture   (D)"
        case #selector(undoDrawing(_:)), #selector(clearDrawings(_:)):
            return wc?.annotations.strokes.isEmpty == false
        case #selector(resetZoom(_:)):
            return wc?.isZoomed == true
        case #selector(fitWindowToPicture(_:)):
            item.toolTip = "Trims the black bars around the picture. The picture stays the same size."
            return wc?.canFitWindowToPicture == true
        case #selector(setCropPreset(_:)):
            let c = Settings.crop
            let preset: CropInsets = item.tag == 1 ? .statusBar : item.tag == 2 ? .statusBarAndToolbar : .none
            item.state = c == preset ? .on : .off
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
