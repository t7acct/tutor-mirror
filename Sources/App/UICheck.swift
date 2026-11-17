import AppKit
import CryptoKit
import Network
import VideoToolbox
import dnssd

/// Headless check of the newer features, for developing while the real app
/// is busy mirroring a lesson. Nothing is shown and focus is never taken.
///
///     ./build.sh --test
///     TUTORMIRROR_SELFTEST=ui TUTORMIRROR_CHECK_OUT=/tmp/check \
///       "build/TutorMirror Test.app/Contents/MacOS/TutorMirrorTest"
///
/// Writes PNGs of the windows, the crop/zoom shader output and a snapshot to
/// the output folder, installs the latest GitHub release into a scratch
/// folder there, prints PASS/FAIL lines and exits (status 1 on any failure).
@MainActor
final class UICheck {
    private let app: AppDelegate
    private let out: URL
    private var failures = 0

    init(app: AppDelegate) {
        self.app = app
        let env = ProcessInfo.processInfo.environment
        out = URL(fileURLWithPath: env["TUTORMIRROR_CHECK_OUT"] ?? NSTemporaryDirectory() + "tutormirror-check")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func run() {
        Task {
            await steps()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            print("output: \(out.path)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS" : "FAIL", what)
        fflush(stdout)
        if !ok { failures += 1 }
    }

    private func save(_ image: CGImage?, _ name: String) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            check(false, "image \(name)")
            return
        }
        try? data.write(to: out.appendingPathComponent("\(name).png"))
    }

    private func render(_ window: NSWindow, _ name: String) {
        guard let v = window.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // Put the window's own background behind it, as on screen.
        let image = NSImage(size: v.bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            (window.backgroundColor ?? .windowBackgroundColor).setFill()
            v.bounds.fill()
        }
        rep.draw(in: v.bounds)
        image.unlockFocus()
        save(image.cgImage(forProposedRect: nil, context: nil, hints: nil), name)
        check(window.sharingType == .none, "\(name) is hidden from screen sharing")
    }

    private func render(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            check(false, "image \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        save(rep.cgImage, name)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

    private func press(_ key: String, code: UInt16, in window: NSWindow, repeating: Bool = false) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: key,
                                          charactersIgnoringModifiers: key, isARepeat: repeating, keyCode: code) else {
            return false
        }
        return app.handleKey(event)
    }

    private func checkHoldModes(_ wc: MirrorWindowController, source: SelfTest) async {
        // Submit distinctly coloured frames one at a time through VideoToolbox.
        // The offscreen shader reads the same retained frame as the window.
        let sampleSize = CGSize(width: 64, height: 48)
        func picture() -> CGImage? { wc.videoView.renderOffscreen(size: sampleSize) }
        func pixels(_ image: CGImage?) -> Data? { image?.dataProvider?.data.map { $0 as Data } }

        wc.badge.alphaValue = 0
        wc.toastBadge.alphaValue = 0
        let mw = wc.window!
        let blankScreen = wc.blankOverlay
        check(press("f", code: 3, in: mw) && wc.holdMode == .frozen && blankScreen.isHidden,
              "F freezes the shared picture")
        check(press("f", code: 3, in: mw, repeating: true) && wc.isFrozen,
              "holding F keeps the picture frozen")
        render(wc.badge, "freeze-badge")

        let frozenPixels = pixels(picture())
        await source.sendFrame(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let afterRed = pixels(picture())
        await source.sendFrame(color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        check(app.manager.videoDecoder.statsSnapshot().totalFrames == 3, "the decoder accepted all three test frames")
        check(frozenPixels != nil && afterRed == frozenPixels && pixels(picture()) == frozenPixels,
              "the rendered picture stays pixel-identical while new frames arrive")

        check(press("b", code: 11, in: mw) && wc.holdMode == .blank && !blankScreen.isHidden,
              "B blanks an already frozen picture")
        check(press("b", code: 11, in: mw, repeating: true) && wc.isBlank && !blankScreen.isHidden,
              "holding B keeps the shared picture covered")
        check(blankScreen.isOpaque && blankScreen.frame == mw.contentView?.bounds &&
              mw.contentView?.subviews.last === blankScreen, "the holding screen covers the entire shared picture")
        check(wc.snapshotImage() == nil, "blank does not expose the hidden picture in snapshots")
        render(blankScreen, "blank-screen")
        render(wc.badge, "blank-badge")

        let compactBlank = BlankScreenView()
        compactBlank.setFrameSize(NSSize(width: 230, height: 300))
        render(compactBlank, "blank-screen-compact")
        check(compactBlank.subviews.allSatisfy { compactBlank.bounds.contains($0.frame) },
              "the holding screen fits a small portrait window")

        await checkNotifications(wc)
        check(press("b", code: 11, in: mw) && wc.holdMode == .frozen && blankScreen.isHidden &&
              frozenPixels != nil && pixels(picture()) == frozenPixels, "unblank restores the same frozen frame")
        check(press("f", code: 3, in: mw) && wc.holdMode == nil && !wc.badge.isVisible,
              "a second F press resumes and dismisses the private status panel")

        // Sample the centre of the resumed BGRA image. Blue was sent last,
        // before F was pressed, and no frames have been sent since.
        let resumed = picture()
        save(resumed, "render-resumed")
        let center = resumed.flatMap { image in
            pixels(image).map { bytes in
                let i = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
                return Array(bytes[i..<(i + 3)])
            }
        }
        // The codec can shift the exact RGB values. Check that blue dominates.
        let isBlue = center.map { $0[0] > 180 && Int($0[0]) > 2 * Int(max($0[1], $0[2])) } ?? false
        check(isBlue, "resume renders the newest frame received during freeze (BGR \(center ?? []))")
        check(press("=", code: 24, in: mw, repeating: true) && wc.isZoomed, "holding the zoom key still zooms")
        wc.resetZoom()
    }

    /// The window keeps whatever shape it's given (full screen, Rectangle)
    /// and the picture fits inside it with black bars, even when the picture
    /// changes shape mid-lesson (Goodnotes presentation mode, Split View).
    private func checkWindowShape(_ wc: MirrorWindowController, source: SelfTest) async {
        let mw = wc.window!, v = wc.videoView
        check(mw.contentAspectRatio == .zero, "the window isn't locked to the iPad's shape")
        check(mw.collectionBehavior.contains(.fullScreenPrimary), "the window can go full screen")
        check(wc.window(mw, willUseFullScreenContentSize: NSSize(width: 2560, height: 1440)) == NSSize(width: 2560, height: 1440),
              "full screen uses the whole screen")

        // A monitor-shaped window, as Rectangle's Maximize or full screen leaves it.
        let screen = mw.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let wide = NSRect(x: screen.minX, y: screen.minY, width: min(screen.width, 1600), height: min(screen.height, 900)).integral
        mw.setFrame(wide, display: true)
        await wait(0.2)
        check(mw.frame == wide, "the window takes a widescreen frame (\(mw.frame.size))")
        func pictureFits(_ video: CGSize) -> Bool {
            let c = v.contentRect, b = v.bounds
            let fitsWidth = near(c.width, b.width, 0.002) && c.height <= b.height + 0.5
            let fitsHeight = near(c.height, b.height, 0.002) && c.width <= b.width + 0.5
            return (fitsWidth || fitsHeight) && near(c.width / c.height, video.width / video.height, 0.002)
                && near(c.midX, b.midX, 0.002) && near(c.midY, b.midY, 0.002)
        }
        check(pictureFits(CGSize(width: 4, height: 3)), "the 4:3 picture sits centred with bars at the sides (\(v.contentRect))")

        // Goodnotes presentation mode: the iPad switches to a 16:9 picture.
        await source.setSize(width: 2732, height: 1536)
        await source.sendFrame()
        await wait(0.4)
        check(v.croppedVideoSize == CGSize(width: 2732, height: 1536), "the picture changed to 2732×1536 (\(v.croppedVideoSize))")
        check(mw.frame == wide, "the window stays put when the picture changes shape (\(mw.frame.size))")
        check(pictureFits(CGSize(width: 2732, height: 1536)), "the 16:9 picture fits inside (\(v.contentRect))")

        // Split View, back to the iPad's own shape: still no resize.
        await source.setSize(width: 2048, height: 1536)
        await source.sendFrame()
        await wait(0.4)
        check(v.croppedVideoSize == CGSize(width: 2048, height: 1536), "the picture changed back to 2048×1536")
        check(mw.frame == wide, "the window stays put when the picture changes back (\(mw.frame.size))")

        // Black bars in the image itself, top and bottom on a tall target.
        let letterbox = v.renderOffscreen(size: CGSize(width: 400, height: 600))
        save(letterbox, "render-letterbox")
        let rows = letterbox.flatMap { image -> (top: [UInt8], middle: [UInt8])? in
            guard let data = image.dataProvider?.data as Data? else { return nil }
            // In the leftmost (white) colour bar, above the sweeping marker.
            func px(_ y: Int) -> [UInt8] {
                let i = y * image.bytesPerRow + 20 * 4
                return Array(data[i..<(i + 3)])
            }
            return (px(10), px(image.height * 35 / 100))
        }
        check(rows.map { $0.top.allSatisfy { $0 < 8 } && $0.middle.allSatisfy { $0 > 200 } } ?? false,
              "the picture is letterboxed in black, not stretched (top \(rows?.top ?? []), middle \(rows?.middle ?? []))")

        // Fit Window to Picture trims the bars and leaves the picture where it was.
        let before = wc.pictureFrameOnScreen ?? .zero
        check(wc.canFitWindowToPicture, "Fit Window to Picture is offered while there are bars")
        wc.fitWindowToPicture()
        await wait(0.2)
        let after = wc.pictureFrameOnScreen ?? .zero
        check(near(mw.frame.width / mw.frame.height, 4.0 / 3, 0.005), "the fitted window is the picture's shape (\(mw.frame.size))")
        check(abs(after.minX - before.minX) <= 1 && abs(after.minY - before.minY) <= 1
              && abs(after.width - before.width) <= 1 && abs(after.height - before.height) <= 1,
              "the picture stays the same size in the same place (\(before) → \(after))")
        check(!wc.canFitWindowToPicture, "nothing left to trim")
    }

    private func checkNotifications(_ wc: MirrorWindowController) async {
        wc.showToast("Nothing to save while blank", color: .systemOrange, for: 1)
        check(wc.badge.isVisible && wc.holdMode == .blank && wc.toastBadge.isVisible &&
              wc.toastBadge.frame.maxY < wc.badge.frame.minY,
              "blank status stays visible above a notification")
        render(wc.toastBadge, "toast-badge")
        wc.showToast("Brief replacement", for: 0.15)
        await wait(0.35)
        check(wc.toast == nil && !wc.toastBadge.isVisible && wc.badge.isVisible,
              "the replacement expires and leaves the blank badge visible")

        wc.showToast("Latest", for: 1.4)
        wc.toggleBlank()
        check(wc.badge.isVisible && wc.holdMode == .frozen && wc.toastBadge.isVisible,
              "freeze status stays visible during a notification")
        await wait(0.8)
        check(wc.toast?.text == "Latest" && wc.toastBadge.isVisible,
              "the original notification timer cannot dismiss the latest notification")
        await wait(0.75)
        check(wc.toast == nil && !wc.toastBadge.isVisible && wc.badge.isVisible,
              "the latest notification expires and leaves the freeze badge visible")
        wc.toggleBlank()
    }

    private func steps() async {
        // Version comparison
        check(Updater.isVersion("0.2.0", newerThan: "0.1.1"), "0.2.0 > 0.1.1")
        check(Updater.isVersion("0.1.10", newerThan: "0.1.9"), "0.1.10 > 0.1.9")
        check(!Updater.isVersion("0.1.1", newerThan: "0.1.1"), "0.1.1 not > 0.1.1")
        check(!Updater.isVersion("0.1", newerThan: "0.1.0"), "0.1 == 0.1.0")
        check(Settings.isTestCopy, "running as the test copy")
        check(Settings.portBase == 53000, "test copy uses its own ports")

        // Tutor-only windows. Rendered in light mode so text drawn straight
        // onto the window background shows up in the PNGs.
        NSApp.appearance = NSAppearance(named: .aqua)
        render(WelcomeWindow(), "welcome")
        render(CropPanel(insets: .statusBar), "crop-panel")
        let wc = app.windowController!
        render(wc.drawToolbar, "draw-toolbar")

        let source = SelfTest(decoder: app.manager.videoDecoder)
        source.start(continuous: false)
        await source.sendFrame()
        let v = wc.videoView
        wc.setCrop(.none)
        save(v.renderOffscreen(size: CGSize(width: 1024, height: 768)), "render-full")
        await wait(0.2) // Apply the window resize dispatched by the renderer.
        check(v.croppedVideoSize == CGSize(width: 2048, height: 1536), "stream is 2048×1536 uncropped")

        // The student sees the whole shared window, title bar included, so the
        // title bar shows nothing and the picture fills the window.
        let mw = wc.window!
        check(mw.titleVisibility == .hidden && mw.titlebarAppearsTransparent, "mirror window shows no title")
        check([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { mw.standardWindowButton($0)?.isHidden ?? true },
              "mirror window shows no window buttons")
        check(v.convert(v.bounds, to: nil).size == mw.frame.size, "the picture fills the whole window (\(v.bounds.size) in \(mw.frame.size))")
        check(!mw.title.isEmpty, "the window still has a name for Meet's window list (\(mw.title))")

        await checkHoldModes(wc, source: source)
        await source.sendFrame() // Restore the colour bars for the crop and snapshot checks.

        wc.setCrop(.statusBar)
        await wait(0.3)
        check(near(v.croppedVideoSize.height, 1536 * 0.975), "status-bar crop cuts 2.5% off the top")
        v.zoom(by: 2, around: CGPoint(x: 0.5, y: 0.5))
        await wait(0.2)
        check(near(v.zoomScale, 2), "zoomed to 2×")
        v.pan(by: CGSize(width: 10, height: 10))   // far past the edge: must clamp
        check(near(v.zoomScale, 2), "panning keeps the zoom")
        save(v.renderOffscreen(size: CGSize(width: 1024, height: 749)), "render-crop-zoom")

        let a = wc.annotations
        a.add(Stroke(tool: .pen, color: .systemRed, points: (0...40).map { CGPoint(x: 0.1 + Double($0) * 0.01, y: 0.2 + sin(Double($0) / 4) * 0.05) }))
        a.add(Stroke(tool: .arrow, color: .systemBlue, points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.5, y: 0.5)]))
        a.add(Stroke(tool: .box, color: .systemGreen, points: [CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.9, y: 0.9)]))
        a.add(Stroke(tool: .highlighter, color: .systemRed, points: [CGPoint(x: 0.55, y: 0.3), CGPoint(x: 0.9, y: 0.3)]))
        let snap = wc.snapshotImage()
        check(snap.map { near(Double($0.width), 1024, 0.01) && near(Double($0.height), 749, 0.01) } ?? false,
              "snapshot is the visible part (\(snap?.width ?? 0)×\(snap?.height ?? 0))")
        save(snap, "snapshot")
        a.undo()
        check(a.strokes.count == 3, "undo removes the last drawing")
        a.clear()
        check(a.strokes.isEmpty, "clear removes all drawings")

        wc.resetZoom()
        await wait(0.2)
        check(v.zoomScale == 1, "zoom reset")
        wc.setCrop(.none)

        await checkWindowShape(wc, source: source)

        // Malformed codec data from the network (empty SPS and PPS) used to crash.
        VideoDecoder().configureWithAVCC(Data([1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 0, 1, 0, 0]))
        check(true, "empty SPS/PPS is ignored without crashing")

        // An error shows a Retry button; leaving the error hides it again.
        func retryVisible() -> Bool {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == "Retry" { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            return wc.window?.contentView.flatMap(find).map { !$0.isHidden } ?? false
        }
        app.manager.state = .error("Port 53000 is already in use.")
        await wait(0.3)
        check(retryVisible(), "an error shows the Retry button")
        app.manager.state = .mirroring("Self-test")
        await wait(0.3)
        check(!retryVisible(), "Retry is hidden while mirroring")

        checkTakeoverRules()
        await checkTakeoverOverNetwork()
        checkPeerToPeer()
        checkHEVC()
        await checkPinPairing()

        // Mouse pointer: swapped for a stand-in only over the mirror window.
        let p = wc.pointer, win = wc.window!
        let inside = NSPoint(x: win.frame.midX, y: win.frame.midY)
        check(p.wantsHidden(at: inside, topWindow: win.windowNumber), "pointer hides over the mirror window")
        check(!p.wantsHidden(at: NSPoint(x: win.frame.maxX + 40, y: win.frame.midY), topWindow: win.windowNumber),
              "pointer shows outside the mirror window")
        check(!p.wantsHidden(at: inside, topWindow: -1), "pointer shows over another app's window on top of the mirror")
        p.enabled = false
        check(!p.wantsHidden(at: inside, topWindow: win.windowNumber), "pointer shows when the setting is off")
        p.enabled = true
        p.drawing = true
        check(p.standIn.frame.size == NSCursor.crosshair.image.size, "draw mode uses a crosshair stand-in")
        p.drawing = false
        check(p.standIn.sharingType == .none, "stand-in pointer is hidden from screen sharing")
        // Really hide it, briefly: a pointer in use here only blinks. macOS
        // also hides the pointer while you type, so only judge the real
        // pointer if it was showing to begin with.
        let visibleBefore = SystemPointer.isVisible
        p.testLocation = (inside, win.windowNumber)
        p.update()
        await wait(0.15)   // the follow timer runs meanwhile and must keep it hidden
        let whileHidden = SystemPointer.isVisible
        let standInShown = p.standIn.isVisible && p.isHiding
        let standInFrame = p.standIn.frame
        p.testLocation = nil
        p.update()
        await wait(0.1)
        check(standInShown, "the stand-in shows in its place")
        check(standInFrame.contains(inside), "the stand-in sits at the pointer")
        check(!p.standIn.isVisible && !p.isHiding, "the stand-in goes away again")
        if visibleBefore == true {
            check(whileHidden == false, "the real pointer hides while TutorMirror is in the background")
            check(SystemPointer.isVisible == true, "the real pointer comes back")
        } else {
            print("SKIP real pointer hide/show: it was already hidden (macOS hides it while you type)")
        }

        // Cost: 0.3.0 asked WindowServer about every mouse move anywhere on the
        // Mac, which made the whole Mac laggy. Away from the mirror it mustn't
        // ask at all; over it, at most 10 times a second.
        let queriesBefore = p.windowQueries
        p.testLocation = (NSPoint(x: win.frame.maxX + 40, y: win.frame.midY), nil)
        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 { p.update() }
        let perMove = (ProcessInfo.processInfo.systemUptime - t0) / 10_000 * 1e6
        check(p.windowQueries == queriesBefore, "mouse moves away from the mirror never ask WindowServer")
        check(perMove < 20, String(format: "a mouse move away from the mirror costs %.1f µs", perMove))
        p.testLocation = (inside, nil)
        for _ in 0..<200 { p.update() }   // well under 0.1 s
        check(p.windowQueries - queriesBefore <= 2, "over the mirror, WindowServer is asked rarely (\(p.windowQueries - queriesBefore) for 200 moves)")
        p.testLocation = nil
        p.update()
        let monitored = p.enabled
        p.enabled = false
        p.update()
        check(monitored && !p.isHiding, "turning the setting off stops it")
        p.enabled = true

        // Updater: fetch the real latest release and install it into a scratch folder.
        do {
            let r = try await Updater.shared.fetchLatest()
            check(r.zipURL != nil, "latest release \(r.version) has a zip")
            let target = out.appendingPathComponent("install-target/TutorMirror.app")
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try "old".write(to: target.appendingPathComponent("Contents/old-version-marker"), atomically: true, encoding: .utf8)
            if let zip = r.zipURL {
                try await Updater.shared.performInstall(r, zip: zip, to: target)
                let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
                check(info?["CFBundleIdentifier"] as? String == "local.tutormirror", "installed app is TutorMirror")
                check(info?["CFBundleShortVersionString"] as? String == r.version, "installed version is \(r.version)")
                check(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/old-version-marker").path),
                      "old copy was replaced")
            }
        } catch {
            check(false, "updater: \(error.localizedDescription)")
        }
    }

    // MARK: Peer-to-peer experiment

    /// The AWDL switches. 0 must set nothing at all; 1 and 2 must match what
    /// `dns-sd` showed reaching awdl0 (see `PeerToPeer`).
    private func checkPeerToPeer() {
        let current = PeerToPeer.current
        check(current == PeerToPeer(setting: Settings.peerToPeer), "running with peerToPeer=\(current.mode.rawValue)")
        check(PeerToPeer(setting: 9).mode == .off && PeerToPeer(setting: -1).mode == .off,
              "peer-to-peer: unknown values count as off")

        /// SO_RECV_ANYIF as read back from a fresh UDP socket after `apply`.
        func recvAnyIf(_ p: PeerToPeer) -> Int32? {
            let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard p.apply(toSocket: fd) == 0 else { return nil }
            var value: Int32 = -1
            var len = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, PeerToPeer.soRecvAnyIf, &value, &len) == 0 ? value : nil
        }
        func includesAWDL(_ p: PeerToPeer) -> (udp: Bool, tcp: Bool) {
            let udp = NWParameters.udp, tcp = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            p.apply(to: udp); p.apply(to: tcp)
            return (udp.includePeerToPeer, tcp.includePeerToPeer)
        }

        let off = PeerToPeer(setting: 0)
        check(off.bonjourFlags == 0 && off.bonjourInterface == 0, "peer-to-peer 0: Bonjour flags 0 and interface 0, as before")
        check(includesAWDL(off) == (false, false), "peer-to-peer 0: listeners and the timing flow leave AWDL out")
        check(recvAnyIf(off) == 0, "peer-to-peer 0: audio sockets don't get SO_RECV_ANYIF")

        let both = PeerToPeer(setting: 1)
        check(both.bonjourFlags == DNSServiceFlags(kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL) && both.bonjourInterface == 0,
              "peer-to-peer 1: advertises on every interface plus AWDL")
        check(includesAWDL(both) == (true, true), "peer-to-peer 1: listeners and the timing flow include AWDL")
        check(recvAnyIf(both) == 1, "peer-to-peer 1: the kernel accepts SO_RECV_ANYIF on audio sockets")

        let only = PeerToPeer(setting: 2)
        let awdl = if_nametoindex("awdl0")
        check(only.bonjourFlags == 0 && only.bonjourInterface == (awdl == 0 ? nil : awdl),
              "peer-to-peer 2: advertises on awdl0 (index \(awdl)) only")
        check(includesAWDL(only) == (true, true) && recvAnyIf(only) == 1, "peer-to-peer 2: every socket can use AWDL")

        // The menu option shows what's running (it takes effect on reopening).
        let menuItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(AppDelegate.toggleDirectLink(_:)) }
        if let menuItem { _ = app.validateMenuItem(menuItem) }
        check(menuItem?.state == (current.isOn ? .on : .off),
              "View › \(menuItem?.title ?? "Connect Directly to iPad (missing)") is \(current.isOn ? "on" : "off")")

        // Tutor-only lag meter: a link line only while the experiment is on.
        // Set and cleared in one go on the main thread, so the 2 s lag log
        // never sees the made-up link.
        let meter = LagMeterPanel()
        LatencyStats.shared.link = "awdl0"
        meter.start()
        meter.stop()
        LatencyStats.shared.link = nil
        render(meter, "lag-meter")
        check(meter.text.contains("awdl0 · direct (AWDL)") == current.isOn,
              "lag meter shows the link \(current.isOn ? "with" : "only with") the experiment on")
    }

    // MARK: H.265 (what the iPad sends over AWDL)

    private final class CountingSink: FrameSink, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
        func display(_ pixelBuffer: CVPixelBuffer, timing: FrameTiming) { lock.lock(); count += 1; lock.unlock() }
        func streamReset() {}
    }

    /// The encoder's output, handed over from its callback thread.
    private final class EncodedFrame: @unchecked Sendable {
        private let lock = NSLock()
        private var _sample: CMSampleBuffer?
        var sample: CMSampleBuffer? {
            get { lock.lock(); defer { lock.unlock() }; return _sample }
            set { lock.lock(); _sample = newValue; lock.unlock() }
        }
    }

    /// Features bit 42 only with the experiment on, and an iPad-style H.265
    /// codec packet (sample description "hvc1" with an hvcC box) followed by
    /// a frame from the Mac's own H.265 encoder makes a picture.
    private func checkHEVC() {
        let on = PeerToPeer.current.isOn
        check(AirPlayConfig.featuresHigh == (on ? 0x400 : 0) && AirPlayConfig.featuresString.hasSuffix(on ? ",0x400" : ",0x0"),
              "features \(AirPlayConfig.featuresString): H.265 (bit 42) offered \(on ? "with" : "only with") the experiment on")

        VideoDecoder().configure(codecData: Data())
        VideoDecoder().configure(codecData: Data([0, 0, 0, 8] + Array("hvc1".utf8) + [0, 0, 0, 12] + Array("hvcC".utf8) + [1, 2, 3]))
        check(true, "empty or cut-off H.265 codec data is ignored without crashing")

        let width = 640, height = 480
        var encoder: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &encoder) == noErr, let encoder else {
            check(false, "H.265 encoder for the check")
            return
        }
        defer { VTCompressionSessionInvalidate(encoder) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { check(false, "pixel buffer for the check"); return }
        let encoded = EncodedFrame()
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            if status == noErr, let sample { encoded.sample = sample }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        guard let sample = encoded.sample, let fmt = sample.formatDescription,
              let atoms = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let hvcC = atoms["hvcC"] as? Data, let src = sample.dataBuffer else {
            check(false, "H.265 frame and hvcC from the encoder")
            return
        }

        // Laid out so the arrays start at 0x75, where UxPlay reads them.
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var packet = [UInt8](repeating: 0, count: 0x56)
        packet.replaceSubrange(4..<8, with: "hvc1".utf8)
        packet += be32(8 + hvcC.count) + Array("hvcC".utf8) + [UInt8](hvcC)
        packet.replaceSubrange(0..<4, with: be32(packet.count))
        let parsed = VideoDecoder.hevcParameterSets(packet)
        check(parsed?.sets.count == 3 && parsed?.nalLength == 4 && packet[0x75] & 0x3F == 32,
              "H.265 codec data: VPS, SPS and PPS found (arrays at 0x75, as UxPlay reads them)")

        let decoder = VideoDecoder()
        let sink = CountingSink()
        decoder.sink = sink
        decoder.configure(codecData: Data(packet))
        let stats = decoder.statsSnapshot()
        check(stats.width == width && stats.height == height, "H.265 format is \(stats.width)×\(stats.height)")
        let len = CMBlockBufferGetDataLength(src)
        var block: CMBlockBuffer?
        CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: src, blockAllocator: nil, customBlockSource: nil,
                                      offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block)
        if let block {
            decoder.decode(block: block, size: len, timing: FrameTiming(senderNTP: 0, receivedHost: HostTime.now, receivedWall: NTPTime.nowSeconds))
            decoder.waitForPendingFrames()
        }
        check(sink.frames == 1, "an H.265 frame decodes to a picture (\(sink.frames))")
        LatencyStats.shared.reset()
    }

    // MARK: On-screen code pairing

    /// From an independent Python version of legacy AirPlay code pairing
    /// (pyatv's conventions): fixed salt, receiver secret b, sender secrets a.
    private enum PinVectors {
        static let user = "5E:B1:22:7C:90:4D", code = "4821"
        static let salt = data("9c52f22665a60c12d289185d950ee881")
        static let b = data("1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d836f675cc")
        static let a1 = data("39263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece")
        static let a2 = data("584cc92f07c597f798e2e95450d7941d27f9c55d14ece04cc98f9bf576a399f8")
        static let m1 = "c9c2bfd0295343b16f7e4753ac736fdc0c42578b", m2 = data("f0c9aeea0d3053972a9340953e8b6e5404536053")
        static let k1 = data("bfed79e40c5030d4f99c893d7a501efb105d30f8fb363892ed84047c74526741bc600d0d8108f6df")
        static func data(_ hex: String) -> Data { Data(PinPairing.hexBytes(hex)) }
        static func A(_ a: Data) -> Data {
            PinPairing.field.power(PinPairing.g, BigUInt(bytes: a)).bytes(length: PinPairing.length)
        }
        static func start() -> [String: Any] {
            PinPairing.codes.set(code)
            PinPairing.codes.testValues = (salt, b)
            return ["method": "pin", "user": user]
        }
    }

    private func plist(_ dict: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
    }

    /// Steps 1 and 2 with the fixed values. Returns the session and the M2 it
    /// sent back, or nil if it refused.
    private func pinProof(a: Data, m1: String) -> (PinPairing.Session, Data?) {
        let session = PinPairing.Session(identity: app.manager.identity)
        guard case .reply(let first) = session.handle(plist(PinVectors.start())),
              first["salt"] as? Data == PinVectors.salt, (first["pk"] as? Data)?.count == 256 else { return (session, nil) }
        guard case .reply(let second) = session.handle(plist(["pk": PinVectors.A(a), "proof": PinVectors.data(m1)])) else {
            return (session, nil)
        }
        return (session, second["proof"] as? Data)
    }

    /// Step 3 as the sender does it: its key sealed under IV+1, and a way to
    /// open the receiver's reply (sealed under IV+2).
    private func senderKeySwap(k: Data, senderKey: Data) -> (request: [String: Any], open: ([String: Any]) -> Data?)? {
        let key = SymmetricKey(data: PinPairing.sha512("Pair-Setup-AES-Key", k).prefix(16))
        var iv = [UInt8](PinPairing.sha512("Pair-Setup-AES-IV", k).prefix(16))
        iv[15] &+= 1
        guard let nonce = try? AES.GCM.Nonce(data: iv), let box = try? AES.GCM.seal(senderKey, using: key, nonce: nonce) else {
            return nil
        }
        iv[15] &+= 1
        let replyIV = iv
        return (["epk": box.ciphertext, "authTag": box.tag], { reply in
            guard let epk = reply["epk"] as? Data, let tag = reply["authTag"] as? Data,
                  let nonce = try? AES.GCM.Nonce(data: replyIV),
                  let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: epk, tag: tag) else { return nil }
            return try? AES.GCM.open(sealed, using: key)
        })
    }

    private func checkPinPairing() async {
        let ours = app.manager.identity.ed25519PublicKey.rawRepresentation
        let (session, m2) = pinProof(a: PinVectors.a1, m1: PinVectors.m1)
        check(m2 == PinVectors.m2, "code pairing: the proof matches the Python reference")
        let senderKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        if let swap = senderKeySwap(k: PinVectors.k1, senderKey: senderKey),
           case .paired(let reply, let theirs) = session.handle(plist(swap.request)) {
            check(theirs == senderKey && swap.open(reply) == ours, "code pairing: Ed25519 keys swapped both ways")
        } else {
            check(false, "code pairing: Ed25519 keys swapped both ways")
        }
        check(PinPairing.codes.current == nil, "code pairing: the code is used up once paired")
        check(pinProof(a: PinVectors.a2, m1: "9145e9d8b8164f82db9402ff2429f031e2c4ae23").1
              == PinVectors.data("66719d9013e1ed50c164075819713583bceb244e"),
              "code pairing: S with a leading zero byte, hashed without it")
        check(pinProof(a: PinVectors.a2, m1: "2b938dc3454b4f08d8dc0671dd5da76974bab516").1
              == PinVectors.data("61c55c8c24e7fdd890b533f643b122c6ff209291"),
              "code pairing: S hashed padded, H(g) padded")
        check(pinProof(a: PinVectors.a1, m1: "a1f2565c814b82d9acbc14bbd60c08b975e41a29").1 == nil
              && PinPairing.codes.current == nil, "code pairing: a wrong code is refused and used up")
        if case .refuse = PinPairing.Session(identity: app.manager.identity).handle(plist(["method": "pin", "user": "x"])) {
            check(true, "code pairing: refused when no code is on screen")
        } else {
            check(false, "code pairing: refused when no code is on screen")
        }

        // The iPad trusts the receiver's key after pairing, so it's kept, but
        // only with the experiment on.
        let on = PeerToPeer.current.isOn
        let again = ReceiverIdentity.make(slot: 0, name: "check")
        check((again.ed25519PublicKey.rawRepresentation == ours && again.deviceID == app.manager.identity.deviceID) == on,
              "receiver identity is kept across launches \(on ? "with" : "only with") the experiment on")
        if on, let url = ReceiverIdentity.savedURL(slot: 0) {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
            check(mode == 0o600, "the saved identity is readable only by you (\(String(mode ?? 0, radix: 8)))")
        }

        await checkPinPairingOverNetwork()
    }

    /// The whole exchange through a loopback-only server, as the iPad does it.
    private func checkPinPairingOverNetwork() async {
        let manager = app.manager
        let server = AirPlayServer(manager: manager)
        server.start(port: manager.identity.ports.airplay, loopbackOnly: true)
        await wait(0.3)
        await pinPairingSteps(manager)
        server.stop()
        await wait(0.3)
        manager.state = .mirroring("Self-test")
    }

    private func pinPairingSteps(_ manager: AirPlayManager) async {
        let ipad = TestClient(host: "127.0.0.1", port: manager.identity.ports.airplay)
        guard await ipad.open() else { return check(false, "code pairing: connect to the test server") }
        defer { ipad.close() }
        check(await ipad.request("POST", "/pair-pin-start", cseq: 1) == 200, "code pairing: pair-pin-start is answered")
        await wait(0.2)
        let shown = app.windowController.toast?.text ?? ""
        guard PeerToPeer.current.isOn else {
            check(!shown.contains("Code for the iPad"), "code pairing is off without the experiment: no code shown")
            check(await ipad.request("POST", "/pair-setup-pin", cseq: 2, plist: ["method": "pin", "user": "x"]) == 200
                  && ipad.lastBody.isEmpty, "code pairing is off without the experiment: pair-setup-pin unhandled as before")
            return
        }
        check(PinPairing.codes.current.map { shown == "Code for the iPad:  \($0)" } ?? false,
              "code pairing: the code is on the tutor-only badge (\(shown))")
        check(app.windowController.toastBadge.sharingType == .none, "code pairing: the badge is hidden from screen sharing")

        check(await ipad.request("POST", "/pair-setup-pin", cseq: 2, plist: PinVectors.start()) == 200
              && ipad.lastPlist?["salt"] as? Data == PinVectors.salt, "code pairing over the network: step 1")
        check(await ipad.request("POST", "/pair-setup-pin", cseq: 3,
                                 plist: ["pk": PinVectors.A(PinVectors.a1), "proof": PinVectors.data(PinVectors.m1)]) == 200
              && ipad.lastPlist?["proof"] as? Data == PinVectors.m2, "code pairing over the network: step 2")
        let senderKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        if let swap = senderKeySwap(k: PinVectors.k1, senderKey: senderKey) {
            check(await ipad.request("POST", "/pair-setup-pin", cseq: 4, plist: swap.request) == 200
                  && ipad.lastPlist.flatMap(swap.open) == manager.identity.ed25519PublicKey.rawRepresentation,
                  "code pairing over the network: step 3")
        }
        await wait(0.2)
        check(app.windowController.toast?.text == "iPad paired", "code pairing: the badge says the iPad is paired")

        let restarted = await ipad.request("POST", "/pair-setup-pin", cseq: 5, plist: PinVectors.start())
        let wrong = await ipad.request("POST", "/pair-setup-pin", cseq: 6,
                                       plist: ["pk": PinVectors.A(PinVectors.a1), "proof": PinVectors.data("a1f2565c814b82d9acbc14bbd60c08b975e41a29")])
        check(restarted == 200 && wrong == 470, "code pairing over the network: a wrong code gets 470")
        await wait(0.2)
        check(app.windowController.toast?.text.hasPrefix("Wrong code") == true, "code pairing: the badge says the code was wrong")
    }

    // MARK: Takeover protection

    private func checkTakeoverRules() {
        typealias P = TakeoverPolicy
        let t = 1000.0
        let ipad = P.Sender(host: "192.168.1.20", deviceID: "AA:BB:CC:DD:EE:FF", lastRequest: t - 1)
        let quiet = P.Sender(host: "192.168.1.20", deviceID: "AA:BB:CC:DD:EE:FF", lastRequest: t - P.quietAfter - 1)
        let other = "192.168.1.30", otherID = "11:22:33:44:55:66"

        check(P.onConnect(host: other, current: nil, now: t, allowTakeover: false) == .replace,
              "takeover: anyone connects when nobody is mirroring")
        check(P.onConnect(host: "192.168.1.20", current: ipad, now: t, allowTakeover: false) == .replace,
              "takeover: the mirroring iPad's own reconnect goes straight through")
        check(P.onConnect(host: other, current: ipad, now: t, allowTakeover: false) == .check,
              "takeover: another device is checked while the iPad mirrors")
        check(P.onSetup(host: other, deviceID: otherID, current: ipad, now: t, allowTakeover: false) == .refuse,
              "takeover: another device is turned away")
        check(P.onSetup(host: "fe80::1%awdl0", deviceID: "aa:bb:cc:dd:ee:ff", current: ipad, now: t, allowTakeover: false) == .replace,
              "takeover: the same iPad on a new address gets back in")
        check(P.onSetup(host: other, deviceID: nil, current: ipad, now: t, allowTakeover: false) == .replace,
              "takeover: a sender without a device ID is let in")
        check(P.onSetup(host: other, deviceID: otherID, current: P.Sender(host: "192.168.1.20", deviceID: nil, lastRequest: t), now: t, allowTakeover: false) == .replace,
              "takeover: unknown current device ID lets the sender in")
        check(P.onConnect(host: other, current: quiet, now: t, allowTakeover: false) == .replace
              && P.onSetup(host: other, deviceID: otherID, current: quiet, now: t, allowTakeover: false) == .replace,
              "takeover: an iPad that went quiet can be replaced")
        check(P.onConnect(host: other, current: ipad, now: t, allowTakeover: true) == .replace
              && P.onSetup(host: other, deviceID: otherID, current: ipad, now: t, allowTakeover: true) == .replace,
              "takeover: the setting turns protection off")
        check(P.onConnect(host: nil, current: ipad, now: t, allowTakeover: false) == .replace,
              "takeover: an unknown address goes through")
    }

    /// Real connections to a loopback-only server: 127.0.0.1 plays the
    /// tutor's iPad and ::1 another device, since they count as different
    /// addresses.
    private func checkTakeoverOverNetwork() async {
        let manager = app.manager
        let hadSetting = UserDefaults.standard.object(forKey: "allowTakeover") != nil
        let saved = Settings.allowTakeover
        Settings.allowTakeover = false
        let server = AirPlayServer(manager: manager)
        server.start(port: manager.identity.ports.airplay, loopbackOnly: true)
        await wait(0.3)
        await takeoverSteps(manager)
        server.stop()
        await wait(0.3)
        if hadSetting { Settings.allowTakeover = saved } else { UserDefaults.standard.removeObject(forKey: "allowTakeover") }
        manager.state = .mirroring("Self-test")
    }

    private func takeoverSteps(_ manager: AirPlayManager) async {
        let port = manager.identity.ports.airplay

        func session(_ id: String, _ name: String) -> [String: Any] {
            ["deviceID": id, "name": name, "eiv": Data(count: 16)]
        }
        let ipad = TestClient(host: "127.0.0.1", port: port)
        guard await ipad.open() else { return check(false, "takeover: connect to the test server") }
        check(await ipad.request("GET", "/info", cseq: 0) == 200, "takeover: iPad gets /info")
        check(await ipad.request("SETUP", "rtsp://127.0.0.1/1", cseq: 1, plist: session("AA:BB:CC:DD:EE:FF", "Tutor iPad")) == 200,
              "takeover: iPad starts a session")

        let student = TestClient(host: "::1", port: port)
        guard await student.open() else { return check(false, "takeover: second device connects") }
        check(await student.request("GET", "/info", cseq: 0) == 200, "takeover: another device still gets /info")
        check(await student.request("SETUP", "rtsp://[::1]/1", cseq: 1, plist: session("11:22:33:44:55:66", "Student iPhone")) == 453,
              "takeover: another device's SETUP is refused with 453")
        check(await student.closed(within: 2), "takeover: the refused device is disconnected")
        await wait(0.2)
        check(await ipad.request("POST", "/feedback", cseq: 2) == 200, "takeover: the iPad keeps its connection")
        check(manager.state == .connecting("Tutor iPad"), "takeover: the window still shows the iPad (\(manager.state))")
        check(app.windowController.toast?.text == "Kept Student iPhone from taking over",
              "takeover: tutor-only toast says who was kept out")

        // The same iPad from another address (as after a Wi-Fi change) gets back in.
        let again = TestClient(host: "::1", port: port)
        guard await again.open() else { return check(false, "takeover: iPad reconnects") }
        check(await again.request("SETUP", "rtsp://[::1]/1", cseq: 1, plist: session("aa:bb:cc:dd:ee:ff", "Tutor iPad")) == 200,
              "takeover: the same iPad on a new address is let in")
        check(await ipad.closed(within: 2), "takeover: its old connection is closed")
        again.close()
    }
}

/// A bare-bones RTSP client for the takeover check. Every request gives up
/// after a few seconds, so a broken server fails the check instead of hanging it.
private final class TestClient: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "local.tutormirror.check-client")

    init(host: String, port: UInt16) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func open() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume(returning: true) }
                case .failed, .cancelled, .waiting: once.run { cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { once.run { cont.resume(returning: false) } }
        }
    }

    func close() { conn.cancel() }

    /// The body of the last response, and that body as a property list.
    private(set) var lastBody = Data()
    var lastPlist: [String: Any]? {
        try? PropertyListSerialization.propertyList(from: lastBody, format: nil) as? [String: Any]
    }

    /// Sends one request and returns the response's status code, or nil if
    /// the connection closed or nothing came back in time.
    func request(_ method: String, _ path: String, cseq: Int, plist: [String: Any]? = nil) async -> Int? {
        var body = Data()
        var head = "\(method) \(path) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        if let plist, let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
            body = data
            head += "Content-Type: application/x-apple-binary-plist\r\n"
        }
        head += "Content-Length: \(body.count)\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .idempotent)

        var buf = Data()
        while true {
            guard let chunk = await receive(timeout: 5) else { return nil }
            buf += chunk
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            while buf.count - end.upperBound < length {
                guard let more = await receive(timeout: 5) else { return nil }
                buf += more
            }
            lastBody = Data(buf[end.upperBound..<(end.upperBound + length)])
            return header.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        }
    }

    /// True if the server closes the connection within `seconds`.
    func closed(within seconds: Double) async -> Bool {
        await receive(timeout: seconds) == nil && !timedOut
    }

    private var timedOut = false

    /// The next bytes, or nil on close, error or timeout (`timedOut` says which).
    private func receive(timeout: Double) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let once = Once()
            timedOut = false
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                once.run { cont.resume(returning: data?.isEmpty == false ? data : nil) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.run {
                    self.timedOut = true
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// Runs its block once; later calls do nothing.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
