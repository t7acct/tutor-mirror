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
}
