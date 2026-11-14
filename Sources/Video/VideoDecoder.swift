import Foundation
import VideoToolbox
import CoreMedia
import os

/// Receives decoded pictures. Called on a VideoToolbox thread — must be quick.
protocol FrameSink: AnyObject, Sendable {
    func display(_ pixelBuffer: CVPixelBuffer, timing: FrameTiming)
    func streamReset()
}

/// H.264 decoder tuned for latency.
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
    private var nalLengthSize: Int32 = 4
    private var lastSPS: Data?
    private var lastPPS: Data?
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
        nalLengthSize = 4
        lastSPS = nil
        lastPPS = nil
        sessionLock.unlock()

        statsLock.lock(); stats = Stats(); errorCount = 0; statsLock.unlock()
        LatencyStats.shared.reset()
        ClockSync.shared.reset()
        sink?.streamReset()
        logger.info("Decoder reset")
    }

    // MARK: - Codec config (avcC)

    func configureWithAVCC(_ avcc: Data) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        let b = [UInt8](avcc)
        guard b.count >= 7 else { return }
        nalLengthSize = Int32((b[4] & 0x03) + 1)

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
        guard let s = sps.first, let p = pps.first else {
            logger.error("No SPS/PPS in avcC")
            return
        }
        // Same parameters (e.g. iPad unlock): keep the session so P-frames that
        // reference pre-lock frames still decode.
        if s == lastSPS && p == lastPPS && session != nil { return }

        var desc: CMVideoFormatDescription?
        let status = s.withUnsafeBytes { sp in
            p.withUnsafeBytes { pp in
                let ptrs = [sp.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            pp.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: [s.count, p.count],
                    nalUnitHeaderLength: nalLengthSize, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else {
            logger.error("Format description failed: \(status)")
            return
        }
        lastSPS = s; lastPPS = p
        formatDescription = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        statsLock.lock(); stats.width = Int(dims.width); stats.height = Int(dims.height); statsLock.unlock()
        LatencyStats.shared.setDimensions(Int(dims.width), Int(dims.height))
        logger.info("Video format: \(dims.width)x\(dims.height)")
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

        let status = VTDecompressionSessionDecodeFrame(
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
        if status != noErr { countError(status) }
    }

    private func countError(_ status: OSStatus) {
        statsLock.lock(); errorCount += 1; let n = errorCount; statsLock.unlock()
        if n <= 5 || n % 100 == 0 { logger.error("Decode error \(status) (count \(n))") }
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }
}
