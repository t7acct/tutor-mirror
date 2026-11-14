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
    var enabled: Bool { didSet { update() } }
    /// Draw mode shows a crosshair stand-in instead of the arrow.
    var drawing = false {
        didSet { guard drawing != oldValue else { return }; setImage(); update() }
    }
    private(set) var isHiding = false

    private weak var window: NSWindow?
    private let overlay: NSPanel
    private let imageView = NSImageView()
    private var hotSpot = NSPoint.zero
    private var monitors: [Any] = []
    private var recheck: Timer?

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
        // Mouse moves over other apps (Meet or Zoom is usually in front during a
        // lesson) and over this one. Neither needs any permission.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        window.acceptsMouseMovedEvents = true
        if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            self?.update()
            return event
        }) { monitors.append(m) }
    }

    /// Puts the real pointer back for good (quitting).
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        apply(hide: false, at: .zero)
    }

    /// Checks where the pointer is now. Called on every mouse move, and on a
    /// timer while hiding, so the pointer comes back if the window closes,
    /// moves or gets covered without the mouse moving.
    func update() {
        let point = testLocation?.point ?? NSEvent.mouseLocation
        let top = testLocation?.topWindow ?? topWindow(at: point)
        apply(hide: wantsHidden(at: point, topWindow: top), at: point)
    }

    /// Stands in for the mouse position and the window under it in the self-check.
    var testLocation: (point: NSPoint, topWindow: Int)?

    /// Whether the pointer at `point` (screen coordinates) should be swapped
    /// for the stand-in, given the frontmost window there.
    func wantsHidden(at point: NSPoint, topWindow: Int) -> Bool {
        guard enabled, let window, window.isVisible, !window.isMiniaturized,
              window.frame.contains(point) else { return false }
        // Only when it's over this app's windows (the mirror or a panel on it),
        // not when another app's window is on top of the mirror there.
        return NSApp.windows.contains { $0.windowNumber == topWindow && $0 !== overlay }
    }

    func apply(hide: Bool, at point: NSPoint) {
        if hide {
            overlay.setFrameOrigin(NSPoint(x: point.x - hotSpot.x,
                                           y: point.y - (overlay.frame.height - hotSpot.y)))
        }
        guard hide != isHiding else { return }
        isHiding = hide
        SystemPointer.setHidden(hide)
        if hide {
            overlay.orderFrontRegardless()
            // Dragging or resizing the window sends no mouse events, so follow
            // the pointer on a timer too (it costs next to nothing).
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            recheck = timer
        } else {
            overlay.orderOut(nil)
            recheck?.invalidate()
            recheck = nil
        }
    }

    /// The stand-in, for the self-check.
    var standIn: NSWindow { overlay }

    private func topWindow(at point: NSPoint) -> Int {
        let n = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard n == overlay.windowNumber else { return n }
        return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: overlay.windowNumber)
    }

    private func setImage() {
        let cursor: NSCursor = drawing ? .crosshair : .arrow
        imageView.image = cursor.image
        hotSpot = cursor.hotSpot
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

    /// nil if macOS can't say.
    static var isVisible: Bool? {
        guard let f = dlsym(rtldDefault, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(f, to: IsVisible.self)() != 0
    }
}
