import Foundation
import QuartzCore

// MARK: - Time helpers

enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Seconds on the same clock as CACurrentMediaTime() / CAMetalDrawable.presentedTime.
    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static var now: UInt64 { mach_absolute_time() }
}

enum NTPTime {
    /// 64-bit NTP fixed point → seconds since 1900.
    static func seconds(_ ntp: UInt64) -> Double {
        Double(ntp >> 32) + Double(ntp & 0xFFFF_FFFF) / 4_294_967_296.0
    }

    /// Mac wall clock as seconds since 1900 (same basis as NTPTimingServer).
    static var nowSeconds: Double { Date().timeIntervalSince1970 + 2_208_988_800 }
}

// MARK: - Clock sync

/// Estimates (iPad clock − Mac clock) from the AirPlay timing exchange, using
/// the sample with the smallest round trip (least affected by Wi-Fi jitter).
final class ClockSync: @unchecked Sendable {
    static let shared = ClockSync()

    private let lock = NSLock()
    private var samples: [(offset: Double, rtt: Double)] = []

    func addSample(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) {
        let a = NTPTime.seconds(t1), b = NTPTime.seconds(t2)
        let c = NTPTime.seconds(t3), d = NTPTime.seconds(t4)
        let rtt = (d - a) - (c - b)
        guard rtt >= 0, rtt < 1 else { return }   // garbage or a stale reply
        let offset = ((b - a) + (c - d)) / 2
        lock.lock()
        samples.append((offset, rtt))
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        lock.unlock()
    }

    func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    /// Median Wi-Fi round trip (Mac → iPad → Mac) over the last ~20 s, in seconds.
    var roundTrip: Double? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let r = samples.map(\.rtt).sorted()
        return r[r.count / 2]
    }

    /// Worst recent round trip — shows Wi-Fi hiccups.
    var worstRoundTrip: Double? {
        lock.lock(); defer { lock.unlock() }
        return samples.map(\.rtt).max()
    }

    /// Seconds to subtract from an iPad timestamp to get Mac time, or nil before the first sync.
    var offset: Double? {
        lock.lock(); defer { lock.unlock() }
        return samples.min(by: { $0.rtt < $1.rtt })?.offset
    }
}

// MARK: - Per-frame timing

struct FrameTiming: Sendable {
    /// iPad timestamp from the mirror packet header (NTP format, iPad clock).
    var senderNTP: UInt64
    /// When the whole packet had arrived on the Mac.
    var receivedHost: UInt64
    var receivedWall: Double
    /// When VideoToolbox handed back the decoded picture.
    var decodedHost: UInt64 = 0
}

// MARK: - Rolling stats for the lag meter

final class LatencyStats: @unchecked Sendable {
    static let shared = LatencyStats()

    struct Sample {
        var at: Double            // host seconds when presented
        var network: Double?      // iPad timestamp → fully received on Mac (incl. iPad encode)
        var decode: Double        // received → decoded
        var display: Double       // decoded → on screen
    }

    struct Summary {
        var receivedFPS = 0
        var shownFPS = 0
        var skipped = 0
        var width = 0
        var height = 0
        var network: (avg: Double, p95: Double)?
        var decode: (avg: Double, p95: Double) = (0, 0)
        var display: (avg: Double, p95: Double) = (0, 0)
        var macSide: (avg: Double, p95: Double) = (0, 0)
        var total: (avg: Double, p95: Double)?
        var worstGap = 0.0        // longest wait between two received frames
        var clockSynced = false
    }

    private let lock = NSLock()
    /// Last out-of-range iPad→Mac value, for diagnosing clock-sync problems.
    var lastRejected: Double?
    private var shown: [Sample] = []
    private var received: [Double] = []   // host seconds
    private var skippedTimes: [Double] = []
    private var dims = (0, 0)

    func frameReceived() {
        let t = HostTime.seconds(HostTime.now)
        lock.lock(); received.append(t); trim(now: t); lock.unlock()
    }

    func frameSkipped() {
        let t = HostTime.seconds(HostTime.now)
        lock.lock(); skippedTimes.append(t); lock.unlock()
    }

    func setDimensions(_ w: Int, _ h: Int) {
        lock.lock(); dims = (w, h); lock.unlock()
    }

    func framePresented(_ timing: FrameTiming, presentedAt: Double) {
        let recv = HostTime.seconds(timing.receivedHost)
        let dec = HostTime.seconds(timing.decodedHost)
        var network: Double?
        if let off = ClockSync.shared.offset {
            let sentMac = NTPTime.seconds(timing.senderNTP) - off
            let raw = timing.receivedWall - sentMac
            // The iPad's frame timestamps and clock replies may count from
            // different epochs (1900 vs 1970); accept either.
            for epochFix in [0.0, 2_208_988_800, -2_208_988_800] {
                let n = raw + epochFix
                if n > -0.05 && n < 5 { network = max(0, n); break }
            }
            if network == nil { lastRejected = raw }
        }
        let s = Sample(at: presentedAt, network: network,
                       decode: max(0, dec - recv), display: max(0, presentedAt - dec))
        lock.lock(); shown.append(s); trim(now: presentedAt); lock.unlock()
    }

    private func trim(now: Double) {
        let cutoff = now - 1.0
        if let i = shown.firstIndex(where: { $0.at >= cutoff }) { shown.removeFirst(i) } else { shown.removeAll() }
        if let i = received.firstIndex(where: { $0 >= cutoff }) { received.removeFirst(i) } else { received.removeAll() }
        if let i = skippedTimes.firstIndex(where: { $0 >= cutoff }) { skippedTimes.removeFirst(i) } else { skippedTimes.removeAll() }
    }

    func summary() -> Summary {
        let now = HostTime.seconds(HostTime.now)
        lock.lock()
        trim(now: now)
        let s = shown, r = received, sk = skippedTimes.count, d = dims
        lock.unlock()

        func stat(_ v: [Double]) -> (Double, Double) {
            guard !v.isEmpty else { return (0, 0) }
            let sorted = v.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return (v.reduce(0, +) / Double(v.count), p95)
        }

        var out = Summary()
        out.receivedFPS = r.count
        out.shownFPS = s.count
        out.skipped = sk
        out.width = d.0; out.height = d.1
        out.decode = stat(s.map(\.decode))
        out.display = stat(s.map(\.display))
        out.macSide = stat(s.map { $0.decode + $0.display })
        let nets = s.compactMap(\.network)
        out.clockSynced = !nets.isEmpty
        if !nets.isEmpty {
            out.network = stat(nets)
            out.total = stat(s.compactMap { x in x.network.map { $0 + x.decode + x.display } })
        }
        if r.count > 1 {
            out.worstGap = zip(r.dropFirst(), r).map { $0 - $1 }.max() ?? 0
        }
        return out
    }

    func reset() {
        lock.lock(); shown.removeAll(); received.removeAll(); skippedTimes.removeAll(); dims = (0, 0); lock.unlock()
    }
}
