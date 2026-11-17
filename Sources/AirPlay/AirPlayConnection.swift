import Foundation
import Network
import os

// @unchecked Sendable: all mutable state is confined to `queue` (the
// NWConnection's callback queue; public entry points hop onto it).
final class AirPlayConnection: @unchecked Sendable {
    /// AirPlay RTSP stream type identifiers (the `type` field in a SETUP stream dict).
    private enum StreamType {
        static let screenMirror = 110
        static let audio = 96
    }

    private let logger = Logger(subsystem: "local.tutormirror", category: "AirPlayConnection")
    private let connection: NWConnection
    private weak var manager: AirPlayManager?
    var onClose: (() -> Void)?

    /// What the server tracks for takeover protection.
    enum Activity {
        case request
        case sessionStarted(deviceID: String?)
        case sessionEnded
    }
    /// Called on every request and session change. Set before `start()`.
    var onActivity: ((Activity) -> Void)?
    /// Set (before `start()`) when this sender connected while another device
    /// was mirroring. Its first SETUP waits for the server's answer before it
    /// touches the shared ports or decoder: `done(true)` lets it carry on,
    /// `done(false)` turns it away. Cleared once it's let in.
    var admit: ((_ deviceID: String?, _ name: String?, _ done: @escaping @Sendable (Bool) -> Void) -> Void)?
    /// Waiting for `admit` to answer: requests stay in the buffer until then.
    private var awaitingAdmission = false
    /// Turned away by takeover protection. It never had a session to end.
    private var refused = false

    /// Identifies this connection's session to the manager, so events from a
    /// connection that's being replaced can't clobber the current session's UI.
    private let sessionID = UUID()

    /// Every piece of mutable state here — request handling, stream setup and
    /// teardown, volume — runs on this serial queue. The NWConnection delivers
    /// its callbacks here, and the public entry points hop onto it.
    private let queue = DispatchQueue(label: "local.tutormirror.airplay-connection", qos: .userInteractive)
    /// Set once the connection has been torn down and the manager told.
    private var finished = false
    /// Set by RECORD. A later screen-mirror SETUP on the same connection (the
    /// sender re-establishing streams after a full TEARDOWN) resumes mirroring
    /// in the UI without waiting for a RECORD that may not come again.
    private var hasRecorded = false
    /// The sender's name from session SETUP, for the UI.
    private var senderName: String?

    private var buffer = Data()

    /// This connection's receiver identity (ports, device ID, signing key).
    private let identity: ReceiverIdentity

    // Handlers
    private let pairSetupHandler: PairSetupHandler
    private let pairVerifyHandler: PairVerifyHandler
    private let fairPlayHandler = FairPlayHandler()
    /// On-screen code pairing (peer-to-peer experiment), made on first use.
    private lazy var pinPairing = PinPairing.Session(identity: identity)
    private let pairingLog = Logger(subsystem: "local.tutormirror", category: "Pairing")

    // Mirror stream — ports are derived from this receiver's identity.
    private var mirrorStreamReceiver: MirrorStreamReceiver?
    private var videoStreamPort: UInt16 { identity.ports.video }
    private var timingPort: UInt16 { identity.ports.ntp }
    private var audioStreamPort: UInt16 { identity.ports.audioData }
    private var audioControlPort: UInt16 { identity.ports.audioControl }

    // Audio stream
    private var audioStreamReceiver: AudioStreamReceiver?

    // Volume level — pushed from AirPlayManager via AirPlayServer.setVolume()
    private var currentVolume: Float = Settings.playAudio ? 1.0 : 0.0

    // Event/timing listeners
    private var ntpTimingServer: NTPTimingServer?

    // FairPlay-decrypted key from session SETUP (raw, before SHA-512 derivation)
    private var fairplayKey: Data?
    // Raw eiv from session SETUP — used as AES-CBC IV for audio decryption
    private var sessionEIV: Data?
    // Monotonic request counter for protocol sequence logging
    private var requestSequence: UInt64 = 0

    init(connection: NWConnection, manager: AirPlayManager?) {
        self.connection = connection
        self.manager = manager
        let id = manager?.identity ?? ReceiverIdentity(slot: 0, name: AirPlayConfig.serverName)
        self.identity = id
        self.pairSetupHandler = PairSetupHandler(identity: id)
        self.pairVerifyHandler = PairVerifyHandler(identity: id)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Connection ready")
                if let self { PeerToPeer.logLink("Control", self.connection) }
                self?.receiveData()
            case .failed(let error):
                self?.logger.error("Connection failed: \(error)")
                self?.finish()
            case .cancelled:
                self?.logger.info("Connection cancelled")
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Closes the connection from outside (eviction by a newer sender, receiver
    /// shutdown). The block holds a strong reference, so the manager is always
    /// told the session ended even if the caller drops its last reference now.
    func close(then completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.finish()
            completion?()
        }
    }

    /// Tears everything down exactly once and reports the end of the session.
    /// Must run on `queue`.
    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        shutdownAllResources()
        if !refused { manager?.didEndSession(sessionID) }
        onClose?()
        onClose = nil
        onActivity = nil
        admit = nil
    }

    /// Sets the audio volume on the active audio stream receiver.
    func setVolume(_ volume: Float) {
        queue.async {
            self.currentVolume = volume
            self.audioStreamReceiver?.volume = volume
        }
    }

    /// Full shutdown: stops all listeners, receivers, and helper services.
    /// Called when the control connection itself is closing.
    private func shutdownAllResources() {
        mirrorStreamReceiver?.stop()
        mirrorStreamReceiver = nil
        audioStreamReceiver?.stop()
        audioStreamReceiver = nil
        ntpTimingServer?.stop()
        ntpTimingServer = nil
    }

    /// Resets stream data connections but keeps listeners alive for re-SETUP.
    /// Called on TEARDOWN to allow the same connection to set up new streams
    /// (e.g. after rotation/lock).
    private func resetStreamResources() {
        mirrorStreamReceiver?.resetStream()
        audioStreamReceiver?.resetStream()
        ntpTimingServer?.stop()
        ntpTimingServer = nil
    }

    private func receiveData() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }

            if isComplete {
                self.logger.info("Connection closed by remote")
                self.finish()
                return
            }

            if let error = error {
                self.logger.error("Receive error: \(error)")
                self.finish()
                return
            }

            guard !self.finished else { return }

            self.receiveData()
        }
    }

    private func processBuffer() {
        // Stop as soon as a handler closes the connection (e.g. a rejected
        // pair-verify) — don't act on requests still sitting in the buffer.
        while !buffer.isEmpty && !finished && !awaitingAdmission {
            switch HTTPParser.parse(data: buffer) {
            case .needsMore:
                return
            case .parsed(let request, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                handleRequest(request)
            case .error(let message):
                logger.error("HTTP parse error: \(message)")
                buffer.removeAll()
                finish()
                return
            }
        }
    }

    private func handleRequest(_ request: HTTPRequest) {
        logger.debug(">>> \(request.method) \(request.path) (\(request.body.count) bytes) [seq=\(self.requestSequence)]")
        requestSequence += 1
        onActivity?(.request)

        // A sender still waiting to be let in can't start, stop or record a
        // session: that would touch the stream of the device that's mirroring.
        if admit != nil {
            switch request.method {
            case "SETUP":
                requestAdmission(for: request)
                return
            case "RECORD", "TEARDOWN", "FLUSH":
                sendResponse(HTTPResponse.build(status: 455, statusText: "Method Not Valid in This State", cseq: request.cseq, isRTSP: true))
                return
            default:
                break
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/info"):
            handleInfo(request)

        case ("POST", "/pair-setup"):
            handlePairSetup(request)

        case ("POST", "/pair-verify"):
            handlePairVerify(request)

        // On-screen code pairing, which iOS asks for over AWDL. Only with the
        // peer-to-peer experiment on; otherwise unhandled, as before.
        case ("POST", "/pair-pin-start") where PeerToPeer.current.isOn:
            handlePairPinStart(request)

        case ("POST", "/pair-setup-pin") where PeerToPeer.current.isOn:
            handlePairSetupPin(request)

        case ("POST", "/fp-setup"):
            handleFPSetup(request)

        case ("SETUP", _):
            handleSetup(request)

        case ("RECORD", _):
            handleRecord(request)

        case ("TEARDOWN", _):
            handleTeardown(request)

        case ("SET_PARAMETER", _):
            handleSetParameter(request)

        case ("GET_PARAMETER", _):
            handleGetParameter(request)

        case ("POST", "/feedback"):
            sendResponse(HTTPResponse.ok(cseq: request.cseq))

        case ("POST", "/command"):
            sendResponse(HTTPResponse.ok(cseq: request.cseq))

        case ("POST", "/audioMode"):
            sendResponse(HTTPResponse.ok(cseq: request.cseq))

        case ("FLUSH", _):
            sendResponse(HTTPResponse.ok(cseq: request.cseq, isRTSP: true))

        case ("OPTIONS", _):
            let headers = [
                "Public": "SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER, POST, GET"
            ]
            sendResponse(HTTPResponse.build(headers: headers, cseq: request.cseq, isRTSP: true))

        default:
            logger.warning("Unhandled: \(request.method, privacy: .public) \(request.path, privacy: .public)")
            sendResponse(HTTPResponse.ok(cseq: request.cseq))
        }
    }

    // MARK: - Request Handlers

    private func handleInfo(_ request: HTTPRequest) {
        // The iPhone sends three variants of GET /info:
        // 1. With Content-Type: application/x-apple-binary-plist body containing
        //    {"qualifier": ["txtAirPlay"]} — respond with ONLY the TXT record data
        // 2. With CSeq but no body — respond with full /info plist
        // 3. No CSeq (Bluetooth LE) — not relevant for us
        //
        // UxPlay: if content_type is set, return only txtAirPlay/txtRAOP, then skip
        // all other fields. This is critical for the iPhone's initial discovery.

        if let contentType = request.contentType,
           contentType.contains("application/x-apple-binary-plist"),
           !request.body.isEmpty {
            // Parse qualifier from request body
            if let plist = try? PropertyListSerialization.propertyList(from: request.body, options: [], format: nil) as? [String: Any],
               let qualifier = plist["qualifier"] as? [String],
               let firstQualifier = qualifier.first {
                logger.debug("GET /info with qualifier: \(firstQualifier)")
                let body = AirPlayConfig.infoQualifierResponseData(identity, qualifier: firstQualifier)
                sendResponse(HTTPResponse.okBplist(cseq: request.cseq, body: body))
                return
            }
        }

        logger.debug("GET /info (full response)")
        let body = AirPlayConfig.infoResponseData(identity)
        sendResponse(HTTPResponse.okBplist(cseq: request.cseq, body: body))
    }

    private func handlePairSetup(_ request: HTTPRequest) {
        logger.debug("POST /pair-setup (\(request.body.count) bytes)")
        let responseData = pairSetupHandler.handle(requestBody: request.body)
        sendResponse(HTTPResponse.ok(
            cseq: request.cseq,
            body: responseData,
            contentType: "application/octet-stream"
        ))
    }

    /// The sender wants to pair with a code shown on this Mac.
    private func handlePairPinStart(_ request: HTTPRequest) {
        let code = PinPairing.codes.next()
        pairingLog.notice("pair-pin-start: showing a code")
        manager?.pairingEvent(.code(code))
        sendResponse(HTTPResponse.ok(cseq: request.cseq))
    }

    private func handlePairSetupPin(_ request: HTTPRequest) {
        func send(_ plist: [String: Any]) {
            if let body = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                sendResponse(HTTPResponse.okBplist(cseq: request.cseq, body: body))
            } else {
                sendResponse(HTTPResponse.build(status: 500, statusText: "Internal Server Error", cseq: request.cseq))
            }
        }
        switch pinPairing.handle(request.body) {
        case .reply(let plist):
            send(plist)
        case .paired(let plist, _):
            send(plist)
            manager?.pairingEvent(.paired)
        case .refuse(let reason):
            pairingLog.error("pair-setup-pin refused: \(reason, privacy: .public)")
            if reason == "wrong code" { manager?.pairingEvent(.wrongCode) }
            sendResponse(HTTPResponse.build(status: 470, statusText: "Connection Authorization Required", cseq: request.cseq))
        }
    }

    private func handlePairVerify(_ request: HTTPRequest) {
        logger.debug("POST /pair-verify (\(request.body.count) bytes)")
        switch pairVerifyHandler.handle(requestBody: request.body) {
        case .ok(let responseData):
            sendResponse(HTTPResponse.ok(
                cseq: request.cseq,
                body: responseData,
                contentType: "application/octet-stream"
            ))
        case .reject:
            logger.error("pair-verify rejected — closing connection")
            sendResponse(HTTPResponse.build(status: 470, statusText: "Connection Authorization Required", cseq: request.cseq))
            finish()
        }
    }

    private func handleFPSetup(_ request: HTTPRequest) {
        logger.debug("POST /fp-setup (\(request.body.count) bytes)")
        let responseData = fairPlayHandler.handle(requestBody: request.body)
        sendResponse(HTTPResponse.ok(
            cseq: request.cseq,
            body: responseData,
            contentType: "application/octet-stream"
        ))
    }

    /// Asks the server whether this sender may take over, holding back every
    /// request after this SETUP until it answers.
    private func requestAdmission(for request: HTTPRequest) {
        guard let admit else { return handleSetup(request) }
        let plist = try? PropertyListSerialization.propertyList(from: request.body, options: [], format: nil) as? [String: Any]
        let deviceID = plist?["deviceID"] as? String
        let name = plist?["name"] as? String
        awaitingAdmission = true
        admit(deviceID, name) { [self] allowed in
            queue.async {
                guard !self.finished else { return }
                self.awaitingAdmission = false
                if allowed {
                    self.admit = nil
                    self.handleSetup(request)
                    self.processBuffer()
                } else {
                    // 453 is what AirPlay receivers send when they're busy
                    // with another sender.
                    self.refused = true
                    self.awaitingAdmission = true   // ignore anything else it sends
                    let response = HTTPResponse.build(status: 453, statusText: "Not Enough Bandwidth", cseq: request.cseq, isRTSP: true)
                    self.connection.send(content: response, completion: .contentProcessed { _ in self.finish() })
                }
            }
        }
    }

    private func handleSetup(_ request: HTTPRequest) {
        logger.info("SETUP (\(request.body.count) bytes)")

        guard !request.body.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: request.body, options: [], format: nil) as? [String: Any] else {
            logger.error("SETUP: failed to parse plist")
            sendResponse(HTTPResponse.build(status: 400, statusText: "Bad Request", cseq: request.cseq, isRTSP: true))
            return
        }

        let keys = plist.keys.sorted().joined(separator: ", ")
        logger.debug("SETUP keys: \(keys)")
        if PeerToPeer.current.isOn {
            // Which timing the sender asks for (over AWDL no timing replies come back).
            let streams = (plist["streams"] as? [[String: Any]])?.map { "\($0["type"] ?? "?"): \($0.keys.sorted().joined(separator: ","))" } ?? []
            let timing = ["timingProtocol", "timingPort", "isScreenMirroringSession"].compactMap { k in plist[k].map { "\(k)=\($0)" } }
            logger.notice("SETUP keys: \(keys, privacy: .public) \(timing.joined(separator: " "), privacy: .public) streams: \(streams.joined(separator: "; "), privacy: .public)")
        }

        // UxPlay processes ekey/eiv AND streams sequentially in the same handler,
        // building a single response dict. We match this behavior: both phases
        // contribute to the same response dictionary.
        var responsePlist: [String: Any] = [:]

        // Phase 1: session key exchange (if ekey/eiv present)
        let hasSessionData = plist["ekey"] is Data || plist["eiv"] is Data
        if hasSessionData {
            processSessionSetup(plist: plist)
            responsePlist["eventPort"] = 0
            responsePlist["timingPort"] = Int(timingPort)
            logger.info("Session SETUP processed (eventPort=0, timingPort=\(self.timingPort))")
        }

        // Phase 2: stream setup (if streams present)
        if let streams = plist["streams"] as? [[String: Any]] {
            let responseStreams = processStreamSetup(plist: plist, streams: streams)
            responsePlist["streams"] = responseStreams
        }

        if responsePlist.isEmpty {
            logger.warning("SETUP with neither ekey/eiv nor streams")
            sendResponse(HTTPResponse.ok(cseq: request.cseq, isRTSP: true))
        } else {
            guard let responseData = try? PropertyListSerialization.data(fromPropertyList: responsePlist, format: .binary, options: 0) else {
                logger.error("SETUP: failed to serialize response plist")
                sendResponse(HTTPResponse.build(status: 500, statusText: "Internal Server Error", cseq: request.cseq, isRTSP: true))
                return
            }
            sendResponse(HTTPResponse.okBplist(cseq: request.cseq, body: responseData, isRTSP: true))
        }
    }

    /// Process session key exchange (ekey/eiv). Does NOT send a response.
    private func processSessionSetup(plist: [String: Any]) {
        logger.debug("Session SETUP (event/timing channel)")

        // Reset any existing stream connections from a previous session
        // (handles reconnection after rotation/lock/unlock).
        // Keeps listeners alive to avoid port reuse race conditions.
        resetStreamResources()

        // Start NTP listener fresh for this session
        // Note: UxPlay does NOT use an event port in mirror/audio mode (eventPort=0).
        // We start NTP only; no event listener.
        ntpTimingServer = NTPTimingServer(port: timingPort)
        ntpTimingServer?.start()

        // Extract and decrypt the FairPlay key from ekey
        if let ekey = plist["ekey"] as? Data {
            if let decryptedKey = fairPlayHandler.decryptStreamKey(ekey: ekey) {
                self.fairplayKey = decryptedKey
                logger.debug("FairPlay key decrypted (\(decryptedKey.count) bytes)")
            } else {
                logger.error("Failed to decrypt FairPlay key")
            }
        }

        // Extract eiv — used as the AES-CBC IV for audio decryption
        if let eiv = plist["eiv"] as? Data {
            self.sessionEIV = eiv
            logger.debug("eiv extracted (\(eiv.count) bytes)")
        }

        onActivity?(.sessionStarted(deviceID: plist["deviceID"] as? String))

        // Extract device name for UI state
        if let name = plist["name"] as? String {
            logger.info("Device: \(name)")
            senderName = name
            manager?.didStartConnecting(session: sessionID, deviceName: name)
        }

        // Read the iPhone's timing port and start active NTP sync
        // (Any device on the network can send this, so a bad port is ignored, not trusted.)
        if let remoteTimingPort = (plist["timingPort"] as? Int).flatMap({ UInt16(exactly: $0) }) {
            if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
               case .hostPort(let host, _) = remoteEndpoint {
                ntpTimingServer?.startActiveSync(remoteHost: host, remotePort: remoteTimingPort)
            }
        }

        // Start audio listener eagerly during session SETUP (like UxPlay's raop_rtp_init).
        // UxPlay creates the audio RTP object during session SETUP, before any stream SETUP.
        // This ensures the UDP port is listening before the iPhone might send audio.
        if audioStreamReceiver == nil {
            audioStreamReceiver = AudioStreamReceiver(port: audioStreamPort, controlPort: audioControlPort)
        }
        audioStreamReceiver?.resetStream()
        audioStreamReceiver?.start()
        logger.debug("Audio listener started eagerly on port \(self.audioStreamPort)")
    }

    /// Process stream configuration. Returns the response streams array.
    private func processStreamSetup(plist: [String: Any], streams: [[String: Any]]) -> [[String: Any]] {
        var responseStreams: [[String: Any]] = []

        for stream in streams {
            let type = stream["type"] as? Int ?? -1

            if type == StreamType.screenMirror {
                // Screen mirroring stream — extract streamConnectionID for key derivation
                var streamConnectionID: UInt64 = 0
                if let connID = stream["streamConnectionID"] as? UInt64 {
                    streamConnectionID = connID
                } else if let connID = stream["streamConnectionID"] as? Int64 {
                    streamConnectionID = UInt64(bitPattern: connID)
                } else if let connID = stream["streamConnectionID"] as? Int {
                    streamConnectionID = UInt64(bitPattern: Int64(connID))
                }
                startMirrorStream(streamConnectionID: streamConnectionID)
                if hasRecorded {
                    manager?.didStartMirroring(session: sessionID, deviceName: senderName)
                }
                responseStreams.append([
                    "type": StreamType.screenMirror,
                    "dataPort": Int(videoStreamPort),
                ] as [String: Any])
            } else if type == StreamType.audio {
                // Audio stream
                startAudioStream(streamInfo: stream)
                responseStreams.append([
                    "type": StreamType.audio,
                    "dataPort": Int(audioStreamPort),
                    "controlPort": Int(audioControlPort),
                ] as [String: Any])
            } else {
                logger.warning("Unknown stream type: \(type)")
            }
        }

        logger.info("Stream SETUP: videoPort=\(self.videoStreamPort), audioPort=\(self.audioStreamPort)")
        return responseStreams
    }

    private func handleRecord(_ request: HTTPRequest) {
        logger.info("Handling RECORD - mirroring started!")
        hasRecorded = true
        manager?.didStartMirroring(session: sessionID, deviceName: senderName)
        let headers = [
            "Audio-Latency": "11025",
            "Audio-Jack-Status": "connected; type=analog"
        ]
        sendResponse(HTTPResponse.build(status: 200, headers: headers, cseq: request.cseq, isRTSP: true))
    }

    private func handleSetParameter(_ request: HTTPRequest) {
        // SET_PARAMETER can contain volume, progress, metadata, etc.
        if let contentType = request.contentType {
            logger.debug("SET_PARAMETER content-type: \(contentType)")
        }
        sendResponse(HTTPResponse.ok(cseq: request.cseq, isRTSP: true))
    }

    private func handleGetParameter(_ request: HTTPRequest) {
        // GET_PARAMETER body contains the parameter name(s) to query
        let paramName = String(data: request.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logger.debug("GET_PARAMETER: '\(paramName)'")

        var responseBody = ""
        if paramName.contains("volume") {
            responseBody = String(format: "volume: %.6f\r\n", AirPlayConnection.airPlayVolume(fromLinear: currentVolume))
        }
        // Respond with the parameter value
        sendResponse(HTTPResponse.ok(
            cseq: request.cseq,
            body: Data(responseBody.utf8),
            contentType: responseBody.isEmpty ? nil : "text/parameters",
            isRTSP: true
        ))
    }

    private func handleTeardown(_ request: HTTPRequest) {
        logger.info("TEARDOWN")

        switch AirPlayConnection.teardownScope(body: request.body) {
        case .streams(let types):
            // Selective teardown: only reset the specified stream types
            for type in types {
                logger.debug("Tearing down stream type: \(type)")
                if type == StreamType.screenMirror {
                    mirrorStreamReceiver?.resetStream()
                } else if type == StreamType.audio {
                    audioStreamReceiver?.resetStream()
                }
            }
        case .session:
            // Full teardown (no stream list): the sender has ended the session.
            // Reset stream resources but keep the listeners and the control
            // connection — the sender may SETUP again on it (lock/unlock) — and
            // tell the manager, so the UI doesn't sit on the last frame. iOS 27
            // sends only this typeless TEARDOWN when mirroring stops, with no
            // preceding type-110 teardown, and may keep the connection open.
            resetStreamResources()
            // Reset the decoder here, in order on this queue, so it happens
            // before any re-SETUP on this connection configures a new stream.
            manager?.videoDecoder.reset()
            manager?.didEndSession(sessionID)
            onActivity?(.sessionEnded)
        }

        sendResponse(HTTPResponse.ok(cseq: request.cseq, isRTSP: true))
    }

    enum TeardownScope: Equatable {
        /// Only these stream types (e.g. 110 screen mirror, 96 audio).
        case streams([Int])
        /// The whole session: no body, an unparseable body, or no stream list.
        case session
    }

    static func teardownScope(body: Data) -> TeardownScope {
        guard let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any],
              let streams = plist["streams"] as? [[String: Any]] else {
            return .session
        }
        return .streams(streams.map { $0["type"] as? Int ?? -1 })
    }

    /// AirPlay expresses volume in dB: -30 (quietest) … 0 (full), -144 = muted.
    static func airPlayVolume(fromLinear volume: Float) -> Double {
        guard volume > 0 else { return -144 }
        return max(-30, min(0, 20 * log10(Double(volume))))
    }

    // MARK: - Mirror Stream

    private func startMirrorStream(streamConnectionID: UInt64) {
        guard let manager = manager else { return }

        logger.debug("startMirrorStream: connID=\(streamConnectionID), fpKey=\(self.fairplayKey != nil), ecdh=\(self.pairVerifyHandler.derivedSharedSecret != nil))")

        // Reset the video decoder so it can accept new codec parameters
        manager.videoDecoder.reset()

        // Create receiver lazily (keeps listener alive across rotation)
        if mirrorStreamReceiver == nil {
            mirrorStreamReceiver = MirrorStreamReceiver(port: videoStreamPort, videoDecoder: manager.videoDecoder)
        }

        // Reset any existing data connection, then configure new encryption keys
        mirrorStreamReceiver?.resetStream()

        let ecdhSecret = pairVerifyHandler.derivedSharedSecret
        if ecdhSecret == nil {
            logger.warning("No ECDH secret from pair-verify — decryption will fail")
        }

        mirrorStreamReceiver?.configureEncryption(
            fairplayKey: fairplayKey,
            ecdhSecret: ecdhSecret,
            streamConnectionID: streamConnectionID
        )

        // start() is idempotent — no-ops if listener is already running
        mirrorStreamReceiver?.start()
        logger.debug("Mirror stream receiver started on port \(self.videoStreamPort)")
    }

    // MARK: - Audio Stream

    private func startAudioStream(streamInfo: [String: Any]) {
        // Create receiver lazily (keeps listener alive across rotation)
        if audioStreamReceiver == nil {
            audioStreamReceiver = AudioStreamReceiver(port: audioStreamPort, controlPort: audioControlPort)
        }

        // Apply current volume
        audioStreamReceiver?.volume = currentVolume

        // Reset any existing data connection, then configure for new stream
        audioStreamReceiver?.resetStream()

        let ecdhSecret = pairVerifyHandler.derivedSharedSecret
        audioStreamReceiver?.configure(
            streamInfo: streamInfo,
            fairplayKey: fairplayKey,
            ecdhSecret: ecdhSecret,
            eiv: sessionEIV
        )

        // start() is idempotent — no-ops if listener is already running
        audioStreamReceiver?.start()
        logger.debug("Audio stream receiver started on port \(self.audioStreamPort)")
    }

    // MARK: - Send Response

    private func sendResponse(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                // A failed send means the control connection is broken; tear it
                // down so resources are reclaimed and the manager sees the drop,
                // rather than leaving a half-dead connection waiting for input.
                self?.logger.error("Send error: \(error) — closing connection")
                self?.finish()
            }
        })
    }
}
