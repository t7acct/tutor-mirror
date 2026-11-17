import Foundation
import CryptoKit
import Security
import os

/// Per-receiver identity and port allocation. Each receiver window owns one of
/// these, so multiple receivers can advertise side by side and an iPhone sees
/// them as distinct devices.
///
/// Ephemeral by design: a fresh device ID, signing key, and UUIDs are generated
/// on creation and live only for the lifetime of this object — nothing is
/// persisted, so each receiver is a clean slate every launch. The exception is
/// the peer-to-peer experiment (see `make(slot:name:)`).
///
/// @unchecked Sendable: everything is immutable except `name`, which is
/// guarded by `nameLock`.
final class ReceiverIdentity: @unchecked Sendable {
    struct Ports {
        let airplay: UInt16
        let video: UInt16
        let ntp: UInt16
        let audioData: UInt16
        let audioControl: UInt16
    }

    let slot: Int
    let ports: Ports
    let deviceID: String
    let ed25519PrivateKey: Curve25519.Signing.PrivateKey
    let pairingID: String
    let displayUUID: String

    /// Display name (shown in the AirPlay list and the window title). Mutable so
    /// it can be renamed live; guarded with a lock because the advertising and
    /// connection paths read it off non-main threads.
    private let nameLock = NSLock()
    private var _name: String
    var name: String {
        get { nameLock.lock(); defer { nameLock.unlock() }; return _name }
        set { nameLock.lock(); _name = newValue; nameLock.unlock() }
    }

    convenience init(slot: Int, name: String) {
        self.init(slot: slot, name: name, deviceID: ReceiverIdentity.randomDeviceID(),
                  key: Curve25519.Signing.PrivateKey(), pairingID: UUID().uuidString, displayUUID: UUID().uuidString)
    }

    private init(slot: Int, name: String, deviceID: String, key: Curve25519.Signing.PrivateKey,
                 pairingID: String, displayUUID: String) {
        self.slot = slot
        self._name = name
        self.ports = ReceiverIdentity.ports(forSlot: slot)
        self.deviceID = deviceID
        self.ed25519PrivateKey = key
        self.pairingID = pairingID
        self.displayUUID = displayUUID
    }

    // MARK: Kept across launches (peer-to-peer experiment only)

    /// The receiver's identity: fresh every launch, unless the peer-to-peer
    /// experiment is on. Over AWDL the iPad pairs once with an on-screen code
    /// (`PinPairing`) and then trusts this receiver by its key, so the key and
    /// IDs are kept in Application Support, readable only by you.
    static func make(slot: Int, name: String) -> ReceiverIdentity {
        guard PeerToPeer.current.isOn, let url = savedURL(slot: slot) else {
            return ReceiverIdentity(slot: slot, name: name)
        }
        let log = Logger(subsystem: "local.tutormirror", category: "Pairing")
        if let data = try? Data(contentsOf: url),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let deviceID = saved["deviceID"] as? String,
           let keyData = saved["signingKey"] as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
           let pairingID = saved["pairingID"] as? String,
           let displayUUID = saved["displayUUID"] as? String {
            log.notice("Receiver identity: kept from an earlier launch")
            return ReceiverIdentity(slot: slot, name: name, deviceID: deviceID, key: key,
                                    pairingID: pairingID, displayUUID: displayUUID)
        }
        let fresh = ReceiverIdentity(slot: slot, name: name)
        let saved: [String: Any] = [
            "deviceID": fresh.deviceID,
            "signingKey": fresh.ed25519PrivateKey.rawRepresentation,
            "pairingID": fresh.pairingID,
            "displayUUID": fresh.displayUUID,
        ]
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            log.notice("Receiver identity: new, saved for next time")
        } catch {
            log.error("Receiver identity: couldn't save (\(error.localizedDescription, privacy: .public)); the iPad will ask for a code again next launch")
        }
        return fresh
    }

    /// ~/Library/Application Support/<bundle ID>/receiver-identity-<slot>.plist
    static func savedURL(slot: Int) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("receiver-identity-\(slot).plist")
    }

    var ed25519PublicKey: Curve25519.Signing.PublicKey { ed25519PrivateKey.publicKey }
    var publicKeyHex: String {
        ed25519PublicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }
    var deviceIDBytes: [UInt8] {
        deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }

    /// Slot 0 keeps the historical ports (47000 / 47100 / 47102 / 47103 / 47104).
    /// Each subsequent slot is offset by 1000, preserving the +100/+102/+103/+104
    /// structure so port ranges never collide between receivers.
    static func ports(forSlot slot: Int) -> Ports {
        let base = UInt16(Int(Settings.portBase) + slot * 1000)
        return Ports(airplay: base,
                     video: base + 100,
                     ntp: base + 102,
                     audioData: base + 103,
                     audioControl: base + 104)
    }

    private static func randomDeviceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = bytes[0] & 0xFE | 0x02 // locally administered, unicast
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
