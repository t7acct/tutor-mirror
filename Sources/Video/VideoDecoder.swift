import Foundation
import VideoToolbox
import CoreMedia
import os

/// Receives decoded pictures. Called on a VideoToolbox thread — must be quick.
protocol FrameSink: AnyObject, Sendable {
    func display(_ pixelBuffer: CVPixelBuffer, timing: FrameTiming)
    func streamReset()
}

/// H.264 (and, for the peer-to-peer experiment, H.265) decoder tuned for latency.
///
/// Differences from VirtualMirror's decoder:
/// - outputs the video's native YUV format (no per-frame BGRA conversion pass)
/// - hardware decoder required, real-time mode on
/// - decoded frames go straight to the renderer from the decode thread
///   (VirtualMirror bounced every frame through the main thread and SwiftUI)
///
/// @unchecked Sendable: session state guarded by `sessionLock`, stats by `statsLock`.
final class VideoDecoder: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.tutormirror", category: "VideoDecoder")

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    /// The parameter sets the session was built from (SPS, PPS; or VPS, SPS, PPS).
    private var lastParameterSets: [Data]?
    private let sessionLock = NSLock()

    private let sinkLock = NSLock()
    private weak var _sink: FrameSink?
    var sink: FrameSink? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return _sink }
        set { sinkLock.lock(); _sink = newValue; sinkLock.unlock() }
    }

    struct Stats { var width = 0; var height = 0; var totalFrames = 0 }
    private let statsLock = NSLock()
    private var stats = Stats()
    private var errorCount = 0

    func statsSnapshot() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return stats
    }

    func reset() {
        sessionLock.lock()
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDescription = nil
        lastParameterSets = nil
        sessionLock.unlock()

        statsLock.lock(); stats = Stats(); errorCount = 0; statsLock.unlock()
        LatencyStats.shared.reset()
        ClockSync.shared.reset()
        sink?.streamReset()
        logger.info("Decoder reset")
    }

    // MARK: - Codec config (avcC / hvcC)

    /// A type-1 mirror packet: an avcC record for H.264, or (with features
    /// bit 42 offered) a sample description starting `size "hvc1"` for H.265.
    func configure(codecData: Data) {
        let b = [UInt8](codecData)
        if b.count >= 8, b[4..<8].elementsEqual("hvc1".utf8) {
            configureHEVC(b)
        } else {
            configureWithAVCC(codecData)
        }
    }

    func configureWithAVCC(_ avcc: Data) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        let b = [UInt8](avcc)
        guard b.count >= 7 else { return }
        let nalLength = Int32((b[4] & 0x03) + 1)

        var off = 6
        var sps: [Data] = [], pps: [Data] = []
        for _ in 0..<Int(b[5] & 0x1F) {
            guard off + 2 <= b.count else { break }
            let len = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
            guard off + len <= b.count else { break }
            sps.append(Data(b[off..<off + len])); off += len
        }
        guard off < b.count else { return }
        let numPPS = Int(b[off]); off += 1
        for _ in 0..<numPPS {
            guard off + 2 <= b.count else { break }
            let len = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
            guard off + len <= b.count else { break }
            pps.append(Data(b[off..<off + len])); off += len
        }
        guard let s = sps.first, let p = pps.first, !s.isEmpty, !p.isEmpty else {
            logger.error("No SPS/PPS in avcC")
            return
        }
        install([s, p], nalLength: nalLength, hevc: false)
    }

    /// H.265: the iPad's sample description holds an `hvcC` box (UxPlay reads
    /// its arrays at a fixed 0x75; the box is looked up here instead).
    private func configureHEVC(_ b: [UInt8]) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let parsed = Self.hevcParameterSets(b) else {
            let head = b.prefix(160).map { String(format: "%02x", $0) }.joined()
            logger.error("No VPS/SPS/PPS in the H.265 codec data (\(b.count, privacy: .public) bytes): \(head, privacy: .public)")
            return
        }
        install(parsed.sets, nalLength: parsed.nalLength, hevc: true)
    }

    /// VPS, SPS and PPS (first of each) and the NAL length size from an
    /// HEVCDecoderConfigurationRecord found after an `hvcC` box header.
    static func hevcParameterSets(_ b: [UInt8]) -> (sets: [Data], nalLength: Int32)? {
        let tag = Array("hvcC".utf8)
        guard b.count > 8, let at = (4...(b.count - 4)).first(where: { b[$0..<$0 + 4].elementsEqual(tag) }) else { return nil }
        let record = at + 4
        guard record + 23 <= b.count else { return nil }
        let nalLength = Int32((b[record + 21] & 0x03) + 1)
        var found: [UInt8: Data] = [:]
        var off = record + 23
        for _ in 0..<Int(b[record + 22]) {
            guard off + 3 <= b.count else { break }
            let type = b[off] & 0x3F
            let count = Int(b[off + 1]) << 8 | Int(b[off + 2]); off += 3
            for _ in 0..<count {
                guard off + 2 <= b.count else { break }
                let len = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
                guard off + len <= b.count else { break }
                if found[type] == nil, len > 0 { found[type] = Data(b[off..<off + len]) }
                off += len
            }
        }
        guard let vps = found[32], let sps = found[33], let pps = found[34] else { return nil }
        return ([vps, sps, pps], nalLength)
    }

    /// Builds the format and the decoder session. Caller holds `sessionLock`.
    private func install(_ sets: [Data], nalLength: Int32, hevc: Bool) {
        // Same parameters (e.g. iPad unlock): keep the session so P-frames that
        // reference pre-lock frames still decode.
        if sets == lastParameterSets && session != nil { return }

        let joined = [UInt8](sets.joined())
        var desc: CMVideoFormatDescription?
        let status: OSStatus = joined.withUnsafeBufferPointer { buf in
            var ptrs: [UnsafePointer<UInt8>] = []
            var offset = 0
            for set in sets { ptrs.append(buf.baseAddress! + offset); offset += set.count }
            let sizes = sets.map(\.count)
            return hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: nalLength, extensions: nil, formatDescriptionOut: &desc)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: nalLength, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else {
            logger.error("Format description failed: \(status, privacy: .public)")
            return
        }
        lastParameterSets = sets
        formatDescription = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        statsLock.lock(); stats.width = Int(dims.width); stats.height = Int(dims.height); statsLock.unlock()
        LatencyStats.shared.setDimensions(Int(dims.width), Int(dims.height))
        logger.info("Video format: \(dims.width, privacy: .public)x\(dims.height, privacy: .public) \(hevc ? "H.265" : "H.264", privacy: .public)")
        createSession(desc)
    }

    private func createSession(_ desc: CMVideoFormatDescription) {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }

        // Native 4:2:0 output, IOSurface-backed so Metal can read it with zero copies.
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let hw: [String: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ]

        var newSession: VTDecompressionSession?
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: desc,
            decoderSpecification: hw as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        if status != noErr {
            logger.warning("Hardware decoder unavailable (\(status)), falling back")
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: desc,
                decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &newSession)
        }
        guard status == noErr, let newSession else {
            logger.error("Decompression session failed: \(status)")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    // MARK: - Decode

    /// Lets the headless check inspect the renderer after a known input frame.
    func waitForPendingFrames() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    /// `block` holds decrypted, length-prefixed NAL units for one frame.
    func decode(block: CMBlockBuffer, size: Int, timing: FrameTiming) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session, let formatDescription else { return }

        var timingInfo = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                            decodeTimeStamp: .invalid)
        var sizeVal = size
        var sample: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeVal, sampleBufferOut: &sample)
        guard st == noErr, let sample else { return }

        statsLock.lock(); stats.totalFrames += 1; statsLock.unlock()

        var status = submit(sample, to: session, timing: timing)
        if status == kVTInvalidSessionErr {
            // macOS can invalidate a decoder (sleep/wake, GPU switch). Build a
            // new one with the same format instead of showing a frozen picture
            // until the iPad reconnects. Frames until the next keyframe may
            // not decode, which only costs a moment.
            logger.warning("Decoder session invalidated — recreating")
            createSession(formatDescription)
            if let fresh = self.session { status = submit(sample, to: fresh, timing: timing) }
        }
        if status != noErr { countError(status) }
    }

    private func submit(_ sample: CMSampleBuffer, to session: VTDecompressionSession, timing: FrameTiming) -> OSStatus {
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.countError(status)
                return
            }
            var t = timing
            t.decodedHost = HostTime.now
            self.sink?.display(imageBuffer, timing: t)
        }
    }

    private func countError(_ status: OSStatus) {
        statsLock.lock(); errorCount += 1; let n = errorCount; statsLock.unlock()
        if n <= 5 || n % 100 == 0 { logger.error("Decode error \(status) (count \(n))") }
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }
}
