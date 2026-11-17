import Foundation
import Darwin
import Network
import dnssd
import os

/// Experiment, off by default (`Settings.peerToPeer`): AirPlay over AWDL, the
/// peer-to-peer Wi-Fi link AirDrop uses, so the iPad can send straight to this
/// Mac instead of through the router.
///
/// Which Bonjour registration lands where, checked with `dns-sd` on macOS 27
/// (register a test service, browse with `-i awdl0` and `-i en0`):
///
///     flags 0, interface 0                  en0 only (today)
///     IncludeP2P                            en0 only: AWDL needs IncludeAWDL too
///     IncludeP2P | IncludeAWDL              en0 and awdl0      → mode 1
///     interface awdl0                       awdl0 only         → mode 2
///     kDNSServiceInterfaceIndexP2P          not on awdl0, still seen on en0
struct PeerToPeer: Equatable, Sendable {
    enum Mode: Int, Sendable {
        case off = 0, alsoAWDL = 1, onlyAWDL = 2
    }
    let mode: Mode

    init(setting: Int) { mode = Mode(rawValue: setting) ?? .off }

    /// Read once, at first use: every socket of a session must agree.
    static let current = PeerToPeer(setting: Settings.peerToPeer)

    var isOn: Bool { mode != .off }

    // MARK: Bonjour

    var bonjourFlags: DNSServiceFlags {
        mode == .alsoAWDL ? DNSServiceFlags(kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL) : 0
    }

    /// 0 (every ordinary interface), or awdl0's own index for AWDL only. Nil
    /// when AWDL only is asked for but there's no awdl0 (Wi-Fi off): falling
    /// back to every interface would quietly spoil the test.
    var bonjourInterface: UInt32? {
        guard mode == .onlyAWDL else { return 0 }
        let index = if_nametoindex("awdl0")
        return index == 0 ? nil : index
    }

    // MARK: Sockets

    /// Lets a Network.framework listener or connection use AWDL. Leaves the
    /// parameters exactly as they were when the experiment is off.
    func apply(to params: NWParameters) {
        guard isOn else { return }
        params.includePeerToPeer = true
    }

    /// SO_RECV_ANYIF ("unrestricted inbound processing") from XNU's private
    /// sys/socket.h, not in the SDK. Without it a BSD socket never sees
    /// packets that arrive on AWDL. The kernel accepts it and reads it back
    /// as set, where an unknown option fails with ENOPROTOOPT.
    static let soRecvAnyIf: Int32 = 0x1104

    /// For a raw BSD socket. Returns 0, or errno if the kernel refused.
    /// Does nothing when the experiment is off.
    func apply(toSocket fd: Int32) -> Int32 {
        guard isOn else { return 0 }
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, Self.soRecvAnyIf, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 ? 0 : errno
    }

    // MARK: Which link a connection uses

    private static let lagLog = Logger(subsystem: "local.tutormirror", category: "Lag")

    /// Logs, in the "Lag" category, which interface a ready connection uses,
    /// and returns its name ("en0", "awdl0", "lo0", or "?").
    @discardableResult
    static func logLink(_ what: String, _ connection: NWConnection) -> String {
        let path = connection.currentPath
        let interface = path?.availableInterfaces.first
        let name = interface?.name ?? "?"
        let type = interface.map { "\($0.type)" } ?? "?"
        let remote = path?.remoteEndpoint.map { "\($0)" } ?? "\(connection.endpoint)"
        lagLog.notice("\(what, privacy: .public) link: \(name, privacy: .public) (\(type, privacy: .public)) \(remote, privacy: .public) peerToPeer=\(current.mode.rawValue, privacy: .public)")
        return name
    }

    /// AWDL's interfaces (awdl0, and llw0 that rides along with it).
    static func isPeerToPeer(interface name: String) -> Bool {
        name.hasPrefix("awdl") || name.hasPrefix("llw")
    }

    /// For the lag meter: "awdl0 · direct (AWDL)" or "en0 · through the router".
    static func label(interface name: String) -> String {
        if isPeerToPeer(interface: name) { return "\(name) · direct (AWDL)" }
        if name.hasPrefix("en") { return "\(name) · through the router" }
        return name
    }
}
