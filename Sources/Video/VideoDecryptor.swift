import Foundation
import CommonCrypto
import os

/// AES-128-CTR decryptor for the mirror stream. The counter runs continuously
/// across the whole TCP stream, so one cryptor lives for the stream's lifetime.
///
/// TutorMirror change: decrypts straight from the receive buffer into the
/// decoder's block buffer — no intermediate arrays or Data copies.
final class VideoDecryptor {
    private let logger = Logger(subsystem: "local.tutormirror", category: "VideoDecryptor")
    private var cryptorRef: CCCryptorRef?

    func configure(key: Data, iv: Data) {
        if let ref = cryptorRef { CCCryptorRelease(ref); cryptorRef = nil }

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        if status == kCCSuccess, let ref = cryptor {
            cryptorRef = ref
        } else {
            logger.error("Failed to create AES-CTR cryptor: \(status)")
        }
    }

    var isConfigured: Bool { cryptorRef != nil }

    /// Decrypts `count` bytes from `src` into `dst` (may not overlap). Copies if unconfigured.
    func decrypt(_ src: UnsafeRawPointer, into dst: UnsafeMutableRawPointer, count: Int) {
        guard let ref = cryptorRef else {
            dst.copyMemory(from: src, byteCount: count)
            return
        }
        var moved = 0
        CCCryptorUpdate(ref, src, count, dst, count, &moved)
    }

    deinit {
        if let ref = cryptorRef { CCCryptorRelease(ref) }
    }
}
