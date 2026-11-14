import AppKit

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

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

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

        // Video: wait for the self-test pattern to come through the decoder.
        await wait(2)
        let v = wc.videoView
        check(v.croppedVideoSize == CGSize(width: 2048, height: 1536), "stream is 2048×1536 uncropped")
        save(v.renderOffscreen(size: CGSize(width: 1024, height: 768)), "render-full")

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
}
