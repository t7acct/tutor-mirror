import Foundation
import Network
import os

/// AirPlay NTP-like timing server.
/// Handles both:
/// 1. Responding to timing requests from the iPhone (passive)
/// 2. Actively sending timing requests to the iPhone once a second (active)
///
/// @unchecked Sendable: all mutable state is confined to `stateQueue`.
final class NTPTimingServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.tutormirror", category: "NTPTiming")
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    /// Inbound flows accepted by the listener (the sender's timing requests).
    /// Tracked so `stop()` can cancel them — otherwise each session SETUP
    /// (every lock/unlock) would leak the previous session's flows.
    private var passiveConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeSyncTimer: DispatchSourceTimer?
    /// Serial queue protecting mutable state (sequenceNumber, connections, timer).
    private let stateQueue = DispatchQueue(label: "local.tutormirror.ntptiming", qos: .userInteractive)
    private var sequenceNumber: UInt16 = 0
    let port: UInt16
    /// Where timing traffic shows up, for the peer-to-peer experiment (over
    /// AWDL no replies came back). Logged after 10 requests and at stop.
    private var counts = (sent: 0, repliesOnPort: 0, repliesOnSocket: 0, answered: 0)
    /// Time between our timing requests. Shorter only in the self-check.
    private let requestInterval: TimeInterval

    init(port: UInt16, requestInterval: TimeInterval = 1) {
        self.port = port
        self.requestInterval = requestInterval
    }

    /// Requests sent and replies read on the request socket (self-check).
    var requestCounts: (sent: Int, repliesOnSocket: Int) {
        stateQueue.sync { (counts.sent, counts.repliesOnSocket) }
    }

    func start() {
        stateQueue.sync { _start() }
    }

    private func _start() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            PeerToPeer.current.apply(to: params)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                logger.error("Invalid NTP port: \(self.port)")
                return
            }
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            logger.error("Failed to create NTP listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.logger.info("NTP timing server ready on port \(self?.port ?? 0)")
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener?.start(queue: stateQueue)
    }

    /// Start actively sending NTP timing requests to the iPhone's timing port.
    /// This is critical for keeping the AirPlay session alive.
    func startActiveSync(remoteHost: NWEndpoint.Host, remotePort: UInt16) {
        stateQueue.sync { _startActiveSync(remoteHost: remoteHost, remotePort: remotePort) }
    }

    private func _startActiveSync(remoteHost: NWEndpoint.Host, remotePort: UInt16) {
        logger.info("Starting active NTP sync to \(String(describing: remoteHost)):\(remotePort)")

        guard let nwPort = NWEndpoint.Port(rawValue: remotePort) else {
            logger.error("Invalid remote NTP port: \(remotePort)")
            return
        }

        // Over AWDL the iPad is a scoped link-local address (fe80::…%awdl0,
        // taken from the control connection's path), which an outbound flow
        // can only reach with peer-to-peer allowed.
        let params = NWParameters.udp
        PeerToPeer.current.apply(to: params)
        let connection = NWConnection(
            host: remoteHost,
            port: nwPort,
            using: params
        )
        self.activeConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("NTP active sync connection ready")
                guard let connection, self.activeSyncTimer == nil else { break }
                PeerToPeer.logLink("Timing (to iPad)", connection)
                self.receiveTimingReply(on: connection)
                self.startTimingRequestLoop()
            case .failed(let error):
                self.logger.error("NTP active sync failed: \(error)")
            default:
                break
            }
        }

        connection.start(queue: stateQueue)
    }

    private func logCounts(_ when: String) {
        guard PeerToPeer.current.isOn, counts.sent > 0 else { return }
        logger.notice("Timing \(when, privacy: .public): sent \(self.counts.sent, privacy: .public) requests; replies \(self.counts.repliesOnPort, privacy: .public) on the timing port, \(self.counts.repliesOnSocket, privacy: .public) on the request socket; answered \(self.counts.answered, privacy: .public) iPad requests")
    }

    func stop() {
        stateQueue.sync {
            logCounts("at stop")
            counts = (0, 0, 0, 0)
            activeSyncTimer?.cancel()
            activeSyncTimer = nil
            activeConnection?.cancel()
            activeConnection = nil
            listener?.cancel()
            listener = nil
            for conn in passiveConnections.values {
                conn.cancel()
            }
            passiveConnections.removeAll()
        }
    }

    // MARK: - Active NTP Sync (send requests to iPhone)

    private func startTimingRequestLoop() {
        // Send first request immediately
        sendTimingRequest()

        // Then once a second
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + requestInterval, repeating: requestInterval)
        timer.setEventHandler { [weak self] in
            self?.sendTimingRequest()
        }
        timer.resume()
        self.activeSyncTimer = timer
    }

    private func sendTimingRequest() {
        guard let connection = activeConnection else { return }

        // Build a 32-byte NTP timing request (matches RPiPlay format)
        // Bytes 0-1: RTP header (0x80, 0xd2 = version 2, payload type 210)
        // Bytes 2-3: sequence number (big-endian)
        // Bytes 4-23: zeros
        // Bytes 24-31: transmit timestamp (our send time)
        var request = Data(count: 32)
        request[0] = 0x80
        request[1] = 0xd2

        let seq = sequenceNumber
        sequenceNumber &+= 1
        request[2] = UInt8(seq >> 8)
        request[3] = UInt8(seq & 0xFF)

        // Put our transmit timestamp at offset 24
        let now = currentNTPTimestamp()
        withUnsafeBytes(of: now.bigEndian) { ptr in
            request[24..<32] = Data(ptr)
        }

        counts.sent += 1
        if counts.sent == 10 { logCounts("after 10 requests") }
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("NTP request send error: \(error)")
                return
            }
        })
    }

    /// Reads replies that come back on the request socket, one read at a
    /// time: the next is queued only when this one finishes. This used to
    /// queue a read with every request, once a second, and the iPad often
    /// doesn't answer on this socket (over the direct link it never does), so
    /// the waiting reads piled up. After about an hour, roughly 3,700 of them
    /// overflowed Network's stack and crashed the app.
    private func receiveTimingReply(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, connection === self.activeConnection else { return }
            if let data = data, data.count >= 32 {
                self.counts.repliesOnSocket += 1
                self.recordReply(data, t4: self.currentNTPTimestamp())
            }
            // A UDP error (say, an ICMP "port unreachable") leaves the flow
            // usable, so keep reading while it's ready, but not in a tight
            // loop if the error keeps coming back.
            guard case .ready = connection.state else { return }
            if let error = error {
                self.logger.debug("NTP response error: \(error)")
                self.stateQueue.asyncAfter(deadline: .now() + 1) { [weak self, weak connection] in
                    guard let self, let connection, connection === self.activeConnection else { return }
                    self.receiveTimingReply(on: connection)
                }
            } else {
                self.receiveTimingReply(on: connection)
            }
        }
    }

    /// TutorMirror: turn a timing reply into an iPad↔Mac clock-offset sample
    /// for the lag meter. Reply layout: 8 origin (our send time, echoed),
    /// 16 iPad receive time, 24 iPad transmit time.
    private var loggedReplies = 0
    private func recordReply(_ data: Data, t4: UInt64) {
        let read: (Int) -> UInt64 = { off in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt64.self).bigEndian }
        }
        let t1 = read(8), t2 = read(16), t3 = read(24)
        if loggedReplies < 3 {
            loggedReplies += 1
            logger.notice("Timing reply t1=\(t1, privacy: .public) t2=\(t2, privacy: .public) t3=\(t3, privacy: .public) t4=\(t4, privacy: .public)")
        }
        ClockSync.shared.addSample(t1: t1, t2: t2, t3: t3, t4: t4)
    }

    // MARK: - Passive NTP (respond to iPhone's requests)

    private func handleConnection(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        passiveConnections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if PeerToPeer.current.isOn { PeerToPeer.logLink("Timing (from iPad)", conn) }
                self?.receiveTimingRequest(on: conn)
            case .failed, .cancelled:
                self?.passiveConnections.removeValue(forKey: id)
            default:
                break
            }
        }
        conn.start(queue: stateQueue)
    }

    private func receiveTimingRequest(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, data.count >= 32 {
                let receiveTime = self.currentNTPTimestamp()
                if data[data.startIndex + 1] == 0xd3 {
                    // A reply to one of OUR timing requests. The iPad sends these
                    // to our advertised timing port, not the request's source port.
                    self.counts.repliesOnPort += 1
                    self.recordReply(data, t4: receiveTime)
                } else {
                    self.counts.answered += 1
                    let response = self.buildTimingResponse(request: data, receiveTime: receiveTime)
                    conn.send(content: response, completion: .contentProcessed { _ in })
                }
            }

            if !isComplete && error == nil {
                self.receiveTimingRequest(on: conn)
            }
        }
    }

    private func buildTimingResponse(request: Data, receiveTime: UInt64) -> Data {
        // AirPlay timing packet: 32 bytes
        // Response format:
        //   Bytes 0-7:   copy from request (marker/RTP header)
        //   Bytes 8-15:  origin timestamp = client's T1 (from request bytes 24-31)
        //   Bytes 16-23: receive timestamp = our time when we got the request (T2)
        //   Bytes 24-31: transmit timestamp = our time when we send the response (T3)

        var response = Data(count: 32)

        // Copy marker bytes (0-7) from request
        response[0..<8] = request[0..<8]

        // Origin timestamp (bytes 8-15) = client's transmit timestamp from request (bytes 24-31)
        response[8..<16] = request[24..<32]

        // Our receive timestamp (bytes 16-23) — captured when packet arrived
        withUnsafeBytes(of: receiveTime.bigEndian) { ptr in
            response[16..<24] = Data(ptr)
        }

        // Our transmit timestamp (bytes 24-31) — captured now, at send time
        let transmitTime = currentNTPTimestamp()
        withUnsafeBytes(of: transmitTime.bigEndian) { ptr in
            response[24..<32] = Data(ptr)
        }

        return response
    }

    /// Returns current time as an NTP timestamp (64-bit: upper 32 = seconds since 1900, lower 32 = fraction)
    private func currentNTPTimestamp() -> UInt64 {
        let ntpEpochOffset: UInt64 = 2208988800
        let now = Date().timeIntervalSince1970
        let seconds = UInt64(now) + ntpEpochOffset
        let fraction = UInt64((now - Double(UInt64(now))) * Double(UInt32.max))
        return (seconds << 32) | fraction
    }
}
