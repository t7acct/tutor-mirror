import AppKit

/// Keeps your mouse pointer out of what the student sees.
///
/// Meet, Zoom and Teams copy the real pointer into the shared picture when
/// it's over the shared window. So while the pointer is over the mirror
/// window, the real one is hidden and a stand-in is drawn in its place in a
/// separate window that screen sharing leaves out. You still see where your
/// mouse is; the student doesn't.
@MainActor
final class PointerHider {
    var enabled: Bool {
        didSet { guard enabled != oldValue else { return }; setMonitoring(enabled); update() }
    }
    /// Draw mode shows a crosshair stand-in instead of the arrow.
    var drawing = false {
        didSet { guard drawing != oldValue else { return }; setImage(); update() }
    }
    private(set) var isHiding = false
    /// Times WindowServer was asked which window is under the pointer (self-check).
    private(set) var windowQueries = 0

    private weak var window: NSWindow?
    private let overlay: NSPanel
    private let imageView = NSImageView()
    private var hotSpot = NSPoint.zero
    private var monitors: [Any] = []
    private var follow: Timer?
    private var topCache: (time: TimeInterval, number: Int)?
    private var lastMove: TimeInterval = 0
    private var lastOrigin: NSPoint?

    init(window: NSWindow, enabled: Bool) {
        self.window = window
        self.enabled = enabled
        overlay = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.sharingType = .none
        overlay.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        imageView.imageScaling = .scaleNone
        overlay.contentView = imageView
        setImage()

        SystemPointer.allowHidingInBackground()
        window.acceptsMouseMovedEvents = true
        setMonitoring(enabled)
    }

    /// Watches mouse moves over other apps (Meet or Zoom is usually in front
    /// during a lesson) and over this one, only while the setting is on.
    /// Neither needs any permission.
    private func setMonitoring(_ on: Bool) {
        if on, monitors.isEmpty {
            let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
                self?.update()
                return event
            }) { monitors.append(m) }
        } else if !on {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
    }

    /// Puts the real pointer back for good (quitting).
    func stop() {
        setMonitoring(false)
        apply(hide: false, at: .zero)
    }

    /// Checks where the pointer is now. Called on every mouse move, and on a
    /// timer while hiding, so the pointer comes back if the window closes,
    /// moves or gets covered without the mouse moving.
    func update() {
        let point = testLocation?.point ?? NSEvent.mouseLocation
        // Cheap test first. Away from the mirror, which is nearly all the
        // time, WindowServer isn't asked anything: it also draws the whole
        // screen, and asking it on every mouse move (0.2 ms each time)
        // slowed the Mac down, worst while screen sharing.
        guard isOver(point) else {
            topCache = nil
            if isHiding { apply(hide: false, at: point) }
            return
        }
        let top = testLocation?.topWindow ?? cachedTopWindow(at: point)
        apply(hide: isOurs(top), at: point)
    }

    /// Stands in for the mouse position (and, if given, the window under it)
    /// in the self-check.
    var testLocation: (point: NSPoint, topWindow: Int?)?

    /// Whether the pointer at `point` (screen coordinates) should be swapped
    /// for the stand-in, given the frontmost window there.
    func wantsHidden(at point: NSPoint, topWindow: Int) -> Bool {
        isOver(point) && isOurs(topWindow)
    }

    private func isOver(_ point: NSPoint) -> Bool {
        guard enabled, let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.frame.contains(point)
    }

    /// This app's windows (the mirror or a panel on it), not another app's
    /// window sitting on top of the mirror.
    private func isOurs(_ number: Int) -> Bool {
        NSApp.windows.contains { $0.windowNumber == number && $0 !== overlay }
    }

    func apply(hide: Bool, at point: NSPoint) {
        guard hide != isHiding else {
            if hide {
                moveStandIn(to: point)
                // The front app can bring the pointer back each time it changes
                // its own pointer, e.g. Chrome when the mirror sits on top of the
                // Meet window and Chrome thinks the mouse is over the page.
                SystemPointer.keepHidden()
            }
            return
        }
        isHiding = hide
        if hide {
            moveStandIn(to: point, now: true)
            SystemPointer.setHidden(true)
            overlay.orderFrontRegardless()
            // Dragging or resizing the window sends no mouse events, and the
            // front app can bring the pointer back between them, so check on a
            // timer too. Each check is cheap; see update().
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            follow = timer
        } else {
            SystemPointer.setHidden(false)
            overlay.orderOut(nil)
            follow?.invalidate()
            follow = nil
        }
    }

    /// The stand-in, for the self-check.
    var standIn: NSWindow { overlay }

    /// Moving a window is a WindowServer round trip too, so the stand-in moves
    /// at most once per screen refresh (120 Hz); the timer brings it to where
    /// the mouse stopped.
    private func moveStandIn(to point: NSPoint, now force: Bool = false) {
        let origin = NSPoint(x: point.x - hotSpot.x, y: point.y - (overlay.frame.height - hotSpot.y))
        guard origin != lastOrigin else { return }
        let t = ProcessInfo.processInfo.systemUptime
        guard force || t - lastMove >= 1.0 / 120 else { return }
        lastMove = t
        lastOrigin = origin
        overlay.setFrameOrigin(origin)
    }

    /// The window under the pointer, asked of WindowServer at most 10 times a
    /// second while the pointer is over the mirror.
    private func cachedTopWindow(at point: NSPoint) -> Int {
        let t = ProcessInfo.processInfo.systemUptime
        if let c = topCache, t - c.time < 0.1 { return c.number }
        let n = topWindow(at: point)
        topCache = (t, n)
        return n
    }

    private func topWindow(at point: NSPoint) -> Int {
        windowQueries += 1
        let n = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard n == overlay.windowNumber else { return n }
        return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: overlay.windowNumber)
    }

    private func setImage() {
        let cursor: NSCursor = drawing ? .crosshair : .arrow
        imageView.image = cursor.image
        hotSpot = cursor.hotSpot
        lastOrigin = nil
        let origin = overlay.frame.origin
        overlay.setFrame(NSRect(origin: origin, size: cursor.image.size), display: true)
    }
}

/// The real, system-wide mouse pointer.
enum SystemPointer {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias IsVisible = @convention(c) () -> Int32
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// macOS normally lets only the front app hide the pointer, and during a
    /// lesson that's Meet or Zoom. This window-server setting (the one pointer
    /// utilities use) lifts that. If it's ever missing, hiding still works
    /// while TutorMirror is the front app.
    static func allowHidingInBackground() {
        guard let c = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let s = dlsym(rtldDefault, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(c, to: DefaultConnection.self)()
        _ = unsafeBitCast(s, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func setHidden(_ hidden: Bool) {
        if hidden { CGDisplayHideCursor(CGMainDisplayID()) } else { CGDisplayShowCursor(CGMainDisplayID()) }
    }

    /// If another app has brought the pointer back while it should be hidden,
    /// takes it back. Showing and hiding again makes this app the one in
    /// charge of the pointer; hiding a second time doesn't (tested: with an
    /// app in front changing its pointer every frame, this cut the times it
    /// showed from 137 in 154 checks to 3).
    static func keepHidden() {
        guard isVisible == true else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// nil if macOS can't say.
    static var isVisible: Bool? {
        guard let f = dlsym(rtldDefault, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(f, to: IsVisible.self)() != 0
    }
}
