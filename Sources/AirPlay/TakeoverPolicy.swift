import Foundation

/// Decides whether a newly connecting sender may replace the one that's
/// mirroring. Without this, anyone on the same Wi-Fi who picks this receiver
/// in Screen Mirroring cuts the tutor's iPad off mid-lesson.
///
/// The rules always lean towards letting a sender in, so the tutor's own iPad
/// is never locked out:
/// - nobody is mirroring, or the current sender has gone quiet: let it in
/// - same network address as the current sender (its own reconnect after a
///   rotation, lock/unlock or Wi-Fi blip): let it in straight away
/// - otherwise it may finish connecting, and is checked at its first SETUP,
///   which carries the device ID: same device lets it in, a different one is
///   turned away. If either ID is missing it is let in.
enum TakeoverPolicy {
    /// How long the current sender may send nothing before it counts as gone.
    /// iOS posts /feedback every 2 seconds while mirroring.
    static let quietAfter: TimeInterval = 6

    struct Sender: Equatable {
        /// Remote address of its control connection, e.g. "192.168.1.20".
        var host: String?
        /// `deviceID` from its session SETUP (a MAC-style ID, stable per device).
        var deviceID: String?
        /// When it last sent a request, in `TakeoverPolicy.now()` seconds.
        var lastRequest: TimeInterval
    }

    enum Decision: Equatable {
        /// Close the current sender and carry on.
        case replace
        /// Keep the current sender; decide at this one's first SETUP.
        case check
        /// Keep the current sender; turn this one away.
        case refuse
    }

    /// A new control connection arrived. `current` is the sender with a live
    /// session, if any.
    static func onConnect(host: String?, current: Sender?, now: TimeInterval, allowTakeover: Bool) -> Decision {
        guard !allowTakeover, let current, !isQuiet(current, now: now) else { return .replace }
        guard let host, let currentHost = current.host, host != currentHost else { return .replace }
        return .check
    }

    /// A connection that got `.check` sent its first SETUP.
    static func onSetup(host: String?, deviceID: String?, current: Sender?, now: TimeInterval, allowTakeover: Bool) -> Decision {
        guard !allowTakeover, let current, !isQuiet(current, now: now) else { return .replace }
        if let host, host == current.host { return .replace }
        guard let id = normalized(deviceID), let currentID = normalized(current.deviceID) else { return .replace }
        return id == currentID ? .replace : .refuse
    }

    static func isQuiet(_ sender: Sender, now: TimeInterval) -> Bool {
        now - sender.lastRequest > quietAfter
    }

    /// Seconds on a clock that keeps counting while the Mac sleeps, so a
    /// connection that went silent across a sleep counts as quiet.
    static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
    }

    private static func normalized(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespaces).uppercased(), !id.isEmpty else { return nil }
        return id
    }
}
