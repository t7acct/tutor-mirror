import Foundation
import VideoToolbox
import CoreMedia
import CoreGraphics

/// Developer self-test: encodes a moving test pattern with the Mac's own H.264
/// encoder and pushes it through the real decode → Metal display path, the same
/// way iPad frames arrive. Run with:  TUTORMIRROR_SELFTEST=1 open build/TutorMirror.app
/// (or launch the binary with that env var). No iPad needed.
final class SelfTest: @unchecked Sendable {
    private let decoder: VideoDecoder
    private var encoder: VTCompressionSession?
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var sentConfig = false
    private let queue = DispatchQueue(label: "local.tutormirror.selftest", qos: .userInteractive)
    private let width = 2048, height = 1536

    init(decoder: VideoDecoder) { self.decoder = decoder }

    func start(continuous: Bool = true) {
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard st == noErr, let encoder else { NSLog("SelfTest: encoder failed \(st)"); return }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        guard continuous else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.encodeNext() }
        t.resume()
        timer = t
    }

    /// In the headless check, send one frame and wait for it to reach the renderer.
    func sendFrame(color: CGColor? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let encoder = self.encoder {
                    self.encodeNext(color: color)
                    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                    self.decoder.waitForPendingFrames()
                }
                continuation.resume()
            }
        }
    }

    private func encodeNext(color: CGColor? = nil) {
        if frame > 0 && frame % 120 == 0 {
            let s = LatencyStats.shared.summary()
            func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
            print("SELFTEST \(s.width)x\(s.height) in=\(s.receivedFPS) shown=\(s.shownFPS) skipped=\(s.skipped)"
                  + " encode+feed=\(s.network.map { ms($0.avg) } ?? "-") decode=\(ms(s.decode.avg))/p95 \(ms(s.decode.p95))"
                  + " display=\(ms(s.display.avg))/p95 \(ms(s.display.p95)) gap=\(ms(s.worstGap))"
                  + " netExtra=\(ms(s.netExtra.avg))/p95 \(ms(s.netExtra.p95))")
            fflush(stdout)
        }
        guard let encoder, let pb = makePattern(color: color) else { return }
        let pts = CMTime(value: CMTimeValue(frame), timescale: 60)
        frame += 1
        let sentHost = HostTime.now
        let sentWall = NTPTime.nowSeconds
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.feed(sample, sentHost: sentHost, sentWall: sentWall)
        }
    }

    private func feed(_ sample: CMSampleBuffer, sentHost: UInt64, sentWall: Double) {
        if !sentConfig, let fmt = sample.formatDescription, let avcc = Self.avcC(from: fmt) {
            decoder.configureWithAVCC(avcc)
            sentConfig = true
        }
        guard let src = sample.dataBuffer else { return }
        let len = CMBlockBufferGetDataLength(src)
        var block: CMBlockBuffer?
        CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: src, blockAllocator: nil, customBlockSource: nil,
                                      offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        // Pretend the "iPad" clock equals the Mac clock, so wifi ≈ encode time here.
        let secs = sentWall
        let ntp = (UInt64(secs) << 32) | UInt64((secs - floor(secs)) * 4_294_967_296.0)
        let timing = FrameTiming(senderNTP: ntp, receivedHost: HostTime.now, receivedWall: NTPTime.nowSeconds)
        LatencyStats.shared.frameReceived(senderNTP: ntp, receivedHost: timing.receivedHost)
        decoder.decode(block: block, size: len, timing: timing)
        _ = sentHost
    }

    /// Moving colour bars + a sweeping white bar, so colour errors and stutter are obvious.
    private func makePattern(color: CGColor?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if let color {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return pb
        }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1,1,1),(1,1,0),(0,1,1),(0,1,0),(1,0,1),(1,0,0),(0,0,1),(0,0,0)]
        let barW = CGFloat(width) / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: 0, width: barW, height: CGFloat(height)))
        }
        let x = CGFloat(frame % 120) / 120 * CGFloat(width)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: CGFloat(height) * 0.4, width: 40, height: CGFloat(height) * 0.2))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: x + 10, y: CGFloat(height) * 0.4 + 10, width: 20, height: CGFloat(height) * 0.2 - 20))
        return pb
    }

    /// Builds an avcC record from SPS/PPS — the same format the iPad sends.
    static func avcC(from fmt: CMFormatDescription) -> Data? {
        var count = 0, nal: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
              parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal) == noErr, count >= 2 else { return nil }
        func set(_ i: Int) -> Data? {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                  parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Data(bytes: ptr, count: size)
        }
        guard let sps = set(0), let pps = set(1), sps.count >= 4 else { return nil }
        var d = Data([1, sps[1], sps[2], sps[3], 0xFC | UInt8(nal - 1), 0xE1])
        d.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)]); d.append(sps)
        d.append(1)
        d.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)]); d.append(pps)
        return d
    }
}
