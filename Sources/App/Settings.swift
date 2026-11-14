import Foundation

/// App settings, backed by UserDefaults so they can be tweaked without a
/// rebuild, e.g.:
///
///     defaults write local.tutormirror maxFPS -int 120
///     defaults write local.tutormirror streamWidth -int 2732
///     defaults write local.tutormirror streamHeight -int 2048
///
/// Stream settings (size, fps) are sent to the iPad when it connects, so
/// reconnect the iPad after changing them.
enum Settings {
    private static var d: UserDefaults { .standard }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    /// "TutorMirror", or "TutorMirror Test" for the side-by-side test copy
    /// (`./build.sh --test`).
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TutorMirror"

    /// The test copy has its own bundle ID, so its own settings, and uses
    /// other ports so it can run while the real app is mirroring.
    static let isTestCopy = Bundle.main.bundleIdentifier?.hasSuffix(".test") == true

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Name shown in the iPad's Screen Mirroring list.
    static var receiverName: String {
        get { d.string(forKey: "receiverName") ?? appName }
        set { d.set(newValue, forKey: "receiverName") }
    }

    /// Display size advertised to the iPad: widescreen (16:9), 1536 tall.
    /// Plain mirroring still arrives at the iPad's own shape (2048×1536 for a
    /// 4:3 iPad). Apps that draw their own view for the second screen, like
    /// Goodnotes' presentation mode, fill a 4:3 screen by cutting the sides of
    /// the page, so the screen must be wide. (VirtualMirror asks for 1920×1080,
    /// which is wide too but shrinks a 4:3 iPad to 1440×1080.)
    static var streamWidth: Int { int("streamWidth", 2732) }
    static var streamHeight: Int { int("streamHeight", 1536) }

    /// Max frame rate requested from the iPad. VirtualMirror asks for 30.
    static var maxFPS: Int { int("maxFPS", 60) }

    /// Base TCP/UDP port. Different from VirtualMirror's 47000 so both apps
    /// can run side by side for an A/B lag test.
    static var portBase: UInt16 { UInt16(clamping: int("portBase", isTestCopy ? 53000 : 52000)) }

    /// iPad audio is off by default — tutoring with Goodnotes doesn't need it.
    static var playAudio: Bool {
        get { bool("playAudio", false) }
        set { d.set(newValue, forKey: "playAudio") }
    }

    static var showLagMeter: Bool {
        get { bool("showLagMeter", false) }
        set { d.set(newValue, forKey: "showLagMeter") }
    }

    // MARK: First run and updates

    static var hasSeenWelcome: Bool {
        get { bool("hasSeenWelcome", false) }
        set { d.set(newValue, forKey: "hasSeenWelcome") }
    }

    /// Look for a new release on GitHub when the app opens (never mid-lesson).
    static var autoCheckUpdates: Bool {
        get { bool("autoCheckUpdates", true) }
        set { d.set(newValue, forKey: "autoCheckUpdates") }
    }

    /// A version the user chose to skip, so it isn't offered again.
    static var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set { d.set(newValue, forKey: "skippedVersion") }
    }

    // MARK: Crop

    /// How much of each edge to cut off, as a fraction of the picture
    /// (0.03 = 3%). Lets you hide the iPad status bar or an app's toolbar.
    static var crop: CropInsets {
        get {
            CropInsets(top: d.double(forKey: "cropTop"), bottom: d.double(forKey: "cropBottom"),
                       left: d.double(forKey: "cropLeft"), right: d.double(forKey: "cropRight"))
        }
        set {
            d.set(newValue.top, forKey: "cropTop"); d.set(newValue.bottom, forKey: "cropBottom")
            d.set(newValue.left, forKey: "cropLeft"); d.set(newValue.right, forKey: "cropRight")
        }
    }
}

/// Edges to cut off the picture, each a fraction of the full width or height.
struct CropInsets: Equatable, Sendable {
    var top = 0.0, bottom = 0.0, left = 0.0, right = 0.0

    static let none = CropInsets()
    /// The iPad status bar (clock, battery): about 24 of 1024 points in landscape.
    static let statusBar = CropInsets(top: 0.025)
    /// The status bar plus a note app's toolbar (roughly; adjust with the sliders).
    static let statusBarAndToolbar = CropInsets(top: 0.1)

    var isNone: Bool { self == .none }

    /// Clamped so at least 40% of the picture is always left.
    var clamped: CropInsets {
        func c(_ v: Double) -> Double { min(max(v, 0), 0.3) }
        return CropInsets(top: c(top), bottom: c(bottom), left: c(left), right: c(right))
    }
}
