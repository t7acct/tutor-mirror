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

    /// Name shown in the iPad's Screen Mirroring list.
    static var receiverName: String { d.string(forKey: "receiverName") ?? "TutorMirror" }

    /// Display size advertised to the iPad. 2048×1536 is exactly 4:3, the
    /// shape of an iPad screen, so there are no black bars.
    /// (VirtualMirror asks for 1920×1080, which shrinks a 4:3 iPad to ~1440×1080.)
    static var streamWidth: Int { int("streamWidth", 2048) }
    static var streamHeight: Int { int("streamHeight", 1536) }

    /// Max frame rate requested from the iPad. VirtualMirror asks for 30.
    static var maxFPS: Int { int("maxFPS", 60) }

    /// Base TCP/UDP port. Different from VirtualMirror's 47000 so both apps
    /// can run side by side for an A/B lag test.
    static var portBase: UInt16 { UInt16(clamping: int("portBase", 52000)) }

    /// iPad audio is off by default — tutoring with Goodnotes doesn't need it.
    static var playAudio: Bool {
        get { bool("playAudio", false) }
        set { d.set(newValue, forKey: "playAudio") }
    }

    static var showLagMeter: Bool {
        get { bool("showLagMeter", true) }
        set { d.set(newValue, forKey: "showLagMeter") }
    }
}
