import Foundation
import CryptoKit
import os

/// On-screen code pairing. iOS insists on it before mirroring over a
/// peer-to-peer (AWDL) link, like Apple TV's "enter the code shown on the TV":
///
///     POST /pair-pin-start      show a 4-digit code (tutor-only badge)
///     POST /pair-setup-pin  1   {method: "pin", user}  → {salt, pk: B}
///                           2   {pk: A, proof: M1}     → {proof: M2}
///                           3   {epk, authTag}         → {epk, authTag}
///
/// Legacy AirPlay SRP-6a, as in UxPlay's `-pin` and pyatv's legacy pairing:
/// RFC 5054's 2048-bit group, g = 2, SHA-1, user = the sender's device ID,
/// password = the code, k = H(N | PAD(g)), u = H(PAD(A) | PAD(B)),
/// x = H(s | H(user ":" code)), and Apple's K = H(S | 00000000) | H(S | 00000001).
/// Step 3 swaps Ed25519 public keys sealed with AES-128-GCM (key and IV from
/// SHA-512 of K; the sender's under IV+1, ours under IV+2). Afterwards the
/// sender trusts this receiver's key, so `ReceiverIdentity` keeps it across
/// launches while the experiment is on, and the code is a one-time step.
enum PinPairing {
    /// RFC 5054's 2048-bit group (checked: a safe prime).
    static let N = BigUInt(bytes: hexBytes(
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050"
        + "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50"
        + "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8"
        + "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B"
        + "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748"
        + "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6"
        + "AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
        + "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"))
    static let g = BigUInt(2)
    /// Bytes in N, for padding.
    static let length = 256
    static let field = MontgomeryModulus(N)
    static let k = BigUInt(bytes: sha1(N.bytes(), g.bytes(length: length)))

    /// What the tutor should see.
    enum Event: Sendable {
        case code(String)
        case paired
        case wrongCode
    }

    /// The code on screen. One for the whole receiver: the sender asks for it
    /// on one connection and pairs on the next.
    static let codes = CodeStore()

    final class CodeStore: @unchecked Sendable {
        /// How long a code stays good.
        static let lifetime: TimeInterval = 300
        private let lock = NSLock()
        private var code: String?
        private var shownAt = Date.distantPast
        private var fixed: (salt: Data, b: Data)?

        /// A fresh random code; the previous one stops working.
        func next() -> String {
            let new = String(format: "%04d", Int.random(in: 0...9999))
            set(new)
            return new
        }

        /// Sets the code, or forgets it (nil).
        func set(_ new: String?) {
            lock.lock(); code = new; shownAt = Date(); lock.unlock()
        }

        var current: String? {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(shownAt) < Self.lifetime ? code : nil
        }

        /// Fixed salt and secret for the next attempt (headless check only).
        var testValues: (salt: Data, b: Data)? {
            get { lock.lock(); defer { lock.unlock() }; return fixed }
            set { lock.lock(); fixed = newValue; lock.unlock() }
        }

        fileprivate func takeTestValues() -> (salt: Data, b: Data)? {
            lock.lock(); defer { lock.unlock() }
            let values = fixed
            fixed = nil
            return values
        }
    }

    /// One sender's pairing attempt: the three /pair-setup-pin requests on a
    /// control connection. Confined to that connection's queue.
    final class Session {
        enum Reply {
            case reply([String: Any])
            /// Done: the last reply, and the sender's Ed25519 public key.
            case paired([String: Any], senderKey: Data)
            case refuse(String)
        }

        private let logger = Logger(subsystem: "local.tutormirror", category: "Pairing")
        private let identity: ReceiverIdentity
        private var user: Data?
        private var salt = Data()
        private var b = BigUInt(0), B = BigUInt(0), v = BigUInt(0)
        private var K: Data?

        init(identity: ReceiverIdentity) {
            self.identity = identity
        }

        func handle(_ body: Data) -> Reply {
            guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
                return .refuse("the body isn't a property list")
            }
            if let method = plist["method"] as? String, let user = plist["user"] as? String {
                return start(method: method, user: user)
            }
            if let a = plist["pk"] as? Data, let proof = plist["proof"] as? Data {
                return check(a, proof: proof)
            }
            if let epk = plist["epk"] as? Data, let tag = plist["authTag"] as? Data {
                return swapKeys(epk, tag: tag)
            }
            return .refuse("unexpected step with keys \(plist.keys.sorted())")
        }

        /// Step 1: a salt and B for the code on screen.
        private func start(method: String, user: String) -> Reply {
            guard method == "pin" else { return .refuse("method \(method), not pin") }
            guard let code = codes.current else { return .refuse("no code on screen (or it expired)") }
            let test = codes.takeTestValues()
            let I = Data(user.utf8)
            salt = test?.salt ?? randomBytes(16, nonZeroFirst: true)
            let x = BigUInt(bytes: sha1(salt, sha1(I, Data(":".utf8), Data(code.utf8))))
            v = field.power(g, x)
            repeat {
                b = BigUInt(bytes: test?.b ?? randomBytes(32))
                B = field.sum(field.product(k, v), field.power(g, b))
            } while test == nil && B.bytes().count < length   // no leading zero: one less encoding to guess
            self.user = I
            K = nil
            logger.notice("pair-setup-pin 1: sent salt and B")
            return .reply(["pk": B.bytes(length: length), "salt": salt])
        }

        /// Step 2: check the sender's proof M1, answer with M2. Write-ups of
        /// SRP disagree on which numbers are hashed with their leading zero
        /// bytes (and on H(g)), so each combination is tried. Only a matching
        /// M1 is accepted, and they differ only in a few hashes.
        private func check(_ aBytes: Data, proof: Data) -> Reply {
            guard let I = user else { return .refuse("proof before step 1") }
            let A = BigUInt(bytes: aBytes)
            guard !A.isZero, A < N else { return .refuse("A is out of range") }
            let hN = sha1(N.bytes()), hI = sha1(I)
            let hgForms = distinct([sha1(g.bytes()), sha1(g.bytes(length: length))])
            for uBytes in distinct([sha1(A.bytes(length: length), B.bytes(length: length)), sha1(A.bytes(), B.bytes())]) {
                let u = BigUInt(bytes: uBytes)
                if u.isZero { continue }
                let S = field.power(field.product(A, field.power(v, u)), b)
                for sBytes in distinct([S.bytes(), S.bytes(length: length)]) {
                    let key = sha1(sBytes, Data([0, 0, 0, 0])) + sha1(sBytes, Data([0, 0, 0, 1]))
                    for hg in hgForms {
                        let xor = Data(zip(hN, hg).map { $0 ^ $1 })
                        for xorForm in distinct([xor, Data(xor.drop { $0 == 0 })]) {
                            for a in distinct([A.bytes(), A.bytes(length: length)]) {
                                for bForm in distinct([B.bytes(), B.bytes(length: length)]) {
                                    let m1 = sha1(xorForm, hI, salt, a, bForm, key)
                                    guard m1 == proof else { continue }
                                    K = key
                                    logger.notice("pair-setup-pin 2: code accepted (S \(sBytes.count, privacy: .public) bytes, H(g) over \(hg == hgForms[0] ? 1 : PinPairing.length, privacy: .public), A \(a.count, privacy: .public))")
                                    return .reply(["proof": sha1(a, m1, key)])
                                }
                            }
                        }
                    }
                }
            }
            codes.set(nil)   // a wrong guess uses the code up, so it can't be brute-forced
            return .refuse("wrong code")
        }

        /// Step 3: the sender's Ed25519 public key in, ours out.
        private func swapKeys(_ epk: Data, tag: Data) -> Reply {
            guard let K else { return .refuse("keys before an accepted proof") }
            let key = SymmetricKey(data: sha512("Pair-Setup-AES-Key", K).prefix(16))
            var iv = [UInt8](sha512("Pair-Setup-AES-IV", K).prefix(16))
            do {
                iv[15] &+= 1
                let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: epk, tag: tag)
                let theirs = try AES.GCM.open(sealed, using: key)
                iv[15] &+= 1
                let ours = try AES.GCM.seal(identity.ed25519PublicKey.rawRepresentation, using: key,
                                            nonce: AES.GCM.Nonce(data: iv))
                codes.set(nil)
                self.K = nil
                logger.notice("pair-setup-pin 3: keys swapped, paired")
                return .paired(["epk": ours.ciphertext, "authTag": ours.tag], senderKey: theirs)
            } catch {
                return .refuse("the sender's key didn't decrypt (\(error))")
            }
        }
    }

    // MARK: Helpers

    static func sha1(_ parts: Data...) -> Data {
        var hash = Insecure.SHA1()
        for part in parts { hash.update(data: part) }
        return Data(hash.finalize())
    }

    static func sha512(_ label: String, _ secret: Data) -> Data {
        var hash = SHA512()
        hash.update(data: Data(label.utf8))
        hash.update(data: secret)
        return Data(hash.finalize())
    }

    /// From the system's cryptographic random source.
    static func randomBytes(_ count: Int, nonZeroFirst: Bool = false) -> Data {
        var bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        if nonZeroFirst, !bytes.isEmpty { bytes[0] = UInt8.random(in: 1...255) }
        return Data(bytes)
    }

    static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// The forms without repeats, in order.
    private static func distinct(_ forms: [Data]) -> [Data] {
        var out: [Data] = []
        for form in forms where !out.contains(form) { out.append(form) }
        return out
    }
}
