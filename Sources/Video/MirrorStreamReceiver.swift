import Foundation
import Network
import CoreMedia
import os

/// Receives the AirPlay screen-mirror TCP stream: 128-byte header + payload per packet.
///
/// Based on VirtualMirror's receiver. TutorMirror changes for lower latency:
/// - packets are parsed in place with a read offset; the buffer is compacted at
///   most once per network read (VirtualMirror re-copied the rest of the buffer
///   after every packet)
/// - video payloads are decrypted straight into the decoder's CMBlockBuffer
///   (one pass, no intermediate copies)
/// - each frame is stamped with its arrival time for the lag meter
///
/// @unchecked Sendable: all mutable state is confined to `queue`.
final class MirrorStreamReceiver: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.tutormirror", category: "MirrorStream")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let port: UInt16
    private let videoDecoder: VideoDecoder
    private var videoDecryptor = VideoDecryptor()

    private var buffer = Data()

    private let queue = DispatchQueue(label: "local.tutormirror.mirror-stream", qos: .userInteractive)

    private static let headerSize = 128
    private static let maxVideoPayloadSize: UInt32 = 10_000_000

    private var connectionGeneration: UInt64 = 0
    private var currentDecryptKey: Data?
    private var currentDecryptIV: Data?
    private var videoStreamSuspended = false

    init(port: UInt16, videoDecoder: VideoDecoder) {
        self.port = port
        self.videoDecoder = videoDecoder
    }

    // MARK: - Encryption

    func configureEncryption(fairplayKey: Data?, ecdhSecret: Data?, streamConnectionID: UInt64) {
        queue.sync {
            if let fpKey = fairplayKey, let ecdh = ecdhSecret {
                let (key, iv) = StreamKeyDerivation.deriveMirrorKeys(fairplayKey: fpKey, ecdhSecret: ecdh, streamConnectionID: streamConnectionID)
                currentDecryptKey = key
                currentDecryptIV = iv
                videoDecryptor = VideoDecryptor()
                videoDecryptor.configure(key: key, iv: iv)
                logger.info("Mirror AES key and IV derived for streamConnectionID=\(streamConnectionID)")
            } else {
                currentDecryptKey = nil
                currentDecryptIV = nil
                videoDecryptor = VideoDecryptor()
                logger.warning("Missing fairplayKey or ecdhSecret — video will not be decrypted")
            }
        }
    }

    // MARK: - Lifecycle

    func resetStream() {
        queue.sync {
            connectionGeneration &+= 1
            connection?.cancel()
            connection = nil
            buffer = Data()
            currentDecryptKey = nil
            currentDecryptIV = nil
            videoDecryptor = VideoDecryptor()
            videoStreamSuspended = false
        }
    }

    func start() {
        queue.sync {
            guard listener == nil else { return }
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let params = NWParameters(tls: nil, tcp: tcp)
                params.allowLocalEndpointReuse = true
                params.serviceClass = .interactiveVideo
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
                listener = try NWListener(using: params, on: nwPort)
            } catch {
                logger.error("Failed to create mirror stream listener: \(error)")
                return
            }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.logger.error("Mirror stream listener failed: \(error)")
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleMirrorConnection(conn)
            }
            listener?.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connectionGeneration &+= 1
            connection?.cancel()
            listener?.cancel()
            connection = nil
            listener = nil
            buffer = Data()
        }
    }

    private func handleMirrorConnection(_ nwConnection: NWConnection) {
        connectionGeneration &+= 1
        let gen = connectionGeneration
        connection?.cancel()
        buffer = Data()
        connection = nwConnection
        logger.info("Mirror stream connection accepted (gen=\(gen))")

        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready: self.receiveData(generation: gen)
            case .failed(let error): self.logger.error("Mirror stream connection failed: \(error)")
            default: break
            }
        }
        nwConnection.start(queue: queue)
    }

    private func receiveData(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        // Large reads: after a Wi-Fi hiccup several frames arrive at once and
        // we want them all in one go so the newest can be shown immediately.
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self, generation == self.connectionGeneration else { return }

            if let data = data, !data.isEmpty {
                if self.buffer.isEmpty { self.buffer = data } else { self.buffer.append(data) }
                self.processBuffer()
            }
            if isComplete || error != nil {
                if let error = error { self.logger.error("Mirror stream receive error: \(error)") }
                return
            }
            self.receiveData(generation: generation)
        }
    }

    // MARK: - Packet parsing

    private func processBuffer() {
        let receivedHost = HostTime.now
        let receivedWall = NTPTime.nowSeconds
        var consumed = 0

        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count

            while total - consumed >= Self.headerSize {
                let p = base + consumed
                let payloadSize = p.loadUnaligned(as: UInt32.self).littleEndian
                let payloadType = p.load(fromByteOffset: 4, as: UInt8.self)
                let codecSubFlags = p.load(fromByteOffset: 6, as: UInt8.self)

                if payloadSize > Self.maxVideoPayloadSize {
                    logger.error("Unreasonable payload size \(payloadSize) — dropping buffer")
                    consumed = total
                    return
                }
                let packetSize = Self.headerSize + Int(payloadSize)
                guard total - consumed >= packetSize else { return }

                let ntp = p.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian   // little-endian, unlike the timing packets (matches UxPlay)
                let payload = UnsafeRawBufferPointer(start: p + Self.headerSize, count: Int(payloadSize))

                switch payloadType {
                case 0:
                    let timing = FrameTiming(senderNTP: ntp, receivedHost: receivedHost, receivedWall: receivedWall)
                    handleVideoPayload(payload, timing: timing)
                case 1:
                    handleCodecData(Data(payload), codecSubFlags: codecSubFlags)
                case 2, 5:
                    break   // heartbeat / control
                default:
                    logger.info("Unknown mirror packet type: \(payloadType), size: \(payloadSize)")
                }
                consumed += packetSize
            }
        }

        if consumed >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if consumed > 0 {
            buffer = buffer.subdata(in: consumed..<buffer.count)
        }
    }

    private func handleVideoPayload(_ payload: UnsafeRawBufferPointer, timing: FrameTiming) {
        guard let src = payload.baseAddress, payload.count > 0 else { return }
        let count = payload.count

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return }

        var dst: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dst)
        guard status == kCMBlockBufferNoErr, let dst else { return }

        videoDecryptor.decrypt(src, into: UnsafeMutableRawPointer(dst), count: count)
        LatencyStats.shared.frameReceived(senderNTP: timing.senderNTP, receivedHost: timing.receivedHost)
        videoDecoder.decode(block: block, size: count, timing: timing)
    }

    private func handleCodecData(_ payload: Data, codecSubFlags: UInt8) {
        logger.info("Codec data: \(payload.count) bytes, subFlags=0x\(String(codecSubFlags, radix: 16))")
        guard payload.count >= 8 else { return }
        // 0x56/0x5e = stream suspending (iPad locked/asleep); 0x16/0x1e = active.
        let suspending = (codecSubFlags == 0x56 || codecSubFlags == 0x5e)
        if suspending != videoStreamSuspended {
            videoStreamSuspended = suspending
            logger.info("Video stream \(suspending ? "suspended" : "resumed")")
        }
        // The AES-CTR counter is continuous across codec changes — don't reset it.
        videoDecoder.configureWithAVCC(payload)
    }
}
