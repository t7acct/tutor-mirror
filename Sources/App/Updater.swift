import AppKit
import os

/// Keeps TutorMirror up to date from the GitHub releases page.
///
/// - Checks the latest release when the app opens and every few hours.
/// - Never interrupts a lesson: an update found while mirroring waits until
///   mirroring has stopped and you're back in the app.
/// - "Install and Relaunch" downloads TutorMirror.zip from the release, checks
///   it's a TutorMirror app with a valid signature, swaps it in place of the
///   running copy and reopens it. Your settings are kept.
///
/// To publish an update: bump the version in Resources/Info.plist, then run
/// `./release.sh`, which builds the zip and creates the GitHub release.
@MainActor
final class Updater {
    static let shared = Updater()
    static let repo = "t7acct/tutor-mirror"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL?
        let pageURL: URL
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private let log = Logger(subsystem: "local.tutormirror", category: "Update")

    /// True while mirroring. Automatic checks never show anything then.
    var isBusy: () -> Bool = { false }
    private var pending: Release?
    private var checking = false
    private var installing = false
    private var timer: Timer?
    private var progressWindow: NSPanel?

    // For testing the update flow on the test copy without touching the real app:
    //   TUTORMIRROR_UPDATE_PRETEND_VERSION=0.0.1  act as if this is an old version
    //   TUTORMIRROR_UPDATE_TARGET=/path/TutorMirror.app  install there, don't relaunch
    private let env = ProcessInfo.processInfo.environment
    private var currentVersion: String { env["TUTORMIRROR_UPDATE_PRETEND_VERSION"] ?? Settings.version }
    private var targetOverride: URL? { env["TUTORMIRROR_UPDATE_TARGET"].map { URL(fileURLWithPath: $0) } }

    func start() {
        guard Settings.autoCheckUpdates else { return }
        Task { await check(userInitiated: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Settings.autoCheckUpdates else { return }
                Task { await self.check(userInitiated: false) }
            }
        }
    }

    func setAutomatic(_ on: Bool) {
        Settings.autoCheckUpdates = on
        if on { start() } else { timer?.invalidate(); timer = nil }
    }

    func checkNow() { Task { await check(userInitiated: true) } }

    /// Show an update found earlier, once mirroring has stopped and the app is in front.
    func offerPendingIfAppropriate() {
        guard let r = pending, !isBusy(), NSApp.isActive, !installing else { return }
        pending = nil
        offer(r, userInitiated: false)
    }

    // MARK: Checking

    private func check(userInitiated: Bool) async {
        guard !checking, !installing else { return }
        checking = true
        defer { checking = false }
        do {
            let r = try await fetchLatest()
            log.notice("latest release \(r.version, privacy: .public), running \(self.currentVersion, privacy: .public)")
            guard Self.isVersion(r.version, newerThan: currentVersion) else {
                if userInitiated { info("You're up to date", "\(Settings.appName) \(currentVersion) is the newest version.") }
                return
            }
            if !userInitiated, Settings.skippedVersion == r.version { return }
            if !userInitiated, isBusy() || !NSApp.isActive {
                pending = r   // shown after the lesson
                return
            }
            offer(r, userInitiated: userInitiated)
        } catch {
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { info("Couldn't check for updates", error.localizedDescription) }
        }
    }

    func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("TutorMirror/\(Settings.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct JSON: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let j = try JSONDecoder().decode(JSON.self, from: data)
        let zip = j.assets.first { $0.name == "TutorMirror.zip" } ?? j.assets.first { $0.name.hasSuffix(".zip") }
        let version = j.tag_name.hasPrefix("v") ? String(j.tag_name.dropFirst()) : j.tag_name
        return Release(version: version, notes: j.body ?? "", zipURL: zip?.browser_download_url, pageURL: j.html_url)
    }

    /// "0.2.0" > "0.1.10" > "0.1.9". Missing parts count as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Offering

    /// Why this copy can't replace itself, if it can't.
    private var cannotInstallReason: String? {
        if targetOverride != nil { return nil }
        if Settings.isTestCopy { return "This is the test copy, so it won't replace itself with the release." }
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") {
            return "macOS is running TutorMirror from a temporary location. Move it to the Applications folder first, then open it from there."
        }
        let parent = url.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: url.path) {
            return "TutorMirror doesn't have permission to replace itself in \(parent)."
        }
        return nil
    }

    private func offer(_ r: Release, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "\(Settings.appName) \(r.version) is available"
        var text = "You have \(currentVersion)."
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n\n" + (notes.count > 700 ? String(notes.prefix(700)) + "…" : notes) }
        let reason = r.zipURL == nil ? "This release has no TutorMirror.zip to install." : cannotInstallReason
        if let reason { text += "\n\n" + reason }
        alert.informativeText = text
        alert.addButton(withTitle: reason == nil ? "Install and Relaunch" : "Open Download Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        alert.window.sharingType = .none
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if reason == nil, let zip = r.zipURL {
                Task { await install(r, zip: zip) }
            } else {
                NSWorkspace.shared.open(r.pageURL)
            }
        case .alertThirdButtonReturn:
            Settings.skippedVersion = r.version
        default:
            break
        }
    }

    // MARK: Installing

    private func install(_ r: Release, zip: URL) async {
        guard !installing else { return }
        if isBusy() {
            info("Finish mirroring first", "Stop mirroring from the iPad, then choose Check for Updates… again.")
            return
        }
        installing = true
        showProgress("Downloading \(Settings.appName) \(r.version)…")
        defer { installing = false; hideProgress() }
        do {
            let target = targetOverride ?? Bundle.main.bundleURL
            try await performInstall(r, zip: zip, to: target)
            if targetOverride != nil {
                info("Update installed (test)", "Installed \(r.version) at \(target.path). Not relaunching.")
                return
            }
            relaunch(target)
        } catch {
            log.error("update failed: \(error.localizedDescription, privacy: .public)")
            hideProgress()
            let alert = NSAlert()
            alert.messageText = "The update didn't install"
            alert.informativeText = "\(error.localizedDescription)\n\nYour current version is untouched. You can download the new one from GitHub instead."
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Cancel")
            alert.window.sharingType = .none
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.pageURL) }
        }
    }

    /// Download, check and swap in the new app. No UI, so the `ui` self-check can use it.
    func performInstall(_ r: Release, zip: URL, to target: URL) async throws {
        let newApp = try await downloadAndVerify(zip, version: r.version, nextTo: target)
        // newApp is <work>/unzipped/TutorMirror.app: remove the download afterwards.
        defer { try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent().deletingLastPathComponent()) }
        updateProgress("Installing…")
        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp, backupItemName: nil, options: [])
        log.notice("installed \(r.version, privacy: .public) at \(target.path, privacy: .public)")
    }

    /// Downloads and unzips the release, and checks it before anything is replaced.
    private func downloadAndVerify(_ zip: URL, version: String, nextTo target: URL) async throws -> URL {
        let fm = FileManager.default
        // A scratch folder on the same disk as the app, so the swap is a rename.
        let work = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("TutorMirror-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        var req = URLRequest(url: zip)
        req.timeoutInterval = 120
        let (downloaded, response) = try await URLSession.shared.download(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("The download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let zipFile = work.appendingPathComponent("TutorMirror.zip")
        try fm.moveItem(at: downloaded, to: zipFile)

        let unzipped = work.appendingPathComponent("unzipped")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unzipped.path])
        guard let appName = try fm.contentsOfDirectory(atPath: unzipped.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.message("The download didn't contain an app.")
        }
        let app = unzipped.appendingPathComponent(appName)

        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.message("The downloaded app is damaged (no Info.plist).")
        }
        let expectedID = "local.tutormirror"
        guard info["CFBundleIdentifier"] as? String == expectedID else {
            throw UpdateError.message("The download isn't TutorMirror.")
        }
        guard let v = info["CFBundleShortVersionString"] as? String, !Self.isVersion(version, newerThan: v) else {
            throw UpdateError.message("The download is an older version than the release says.")
        }
        // The release is ad-hoc signed: this checks nothing in the bundle was
        // changed or cut short after it was built.
        do {
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.message("The downloaded app's signature is broken.")
        }
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private func relaunch(_ app: URL) {
        // A tiny helper waits for this copy to quit, then opens the new one.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            info("Update installed", "Quit and reopen \(Settings.appName) to start the new version.")
        }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw UpdateError.message("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).")
            }
        }.value
    }

    // MARK: UI

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.window.sharingType = .none
        alert.runModal()
    }

    private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Updating \(Settings.appName)"
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier("label")
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressWindow = panel
    }

    private func updateProgress(_ text: String) {
        let label = progressWindow?.contentView?.subviews.first { $0.identifier?.rawValue == "label" } as? NSTextField
        label?.stringValue = text
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }
}
