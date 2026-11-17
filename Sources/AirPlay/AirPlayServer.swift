import Foundation
import Network
import dnssd
import os

// @unchecked Sendable: `connections` is guarded by `connectionQueue`; the
// listener and `onFailure` are set up on the main actor before `start()` and
// only torn down there.
final class AirPlayServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.tutormirror", category: "AirPlayServer")
    private var listener: NWListener?

    /// What the server knows about each control connection, for deciding
    /// whether a new sender may take over (see `TakeoverPolicy`).
    private struct Peer {
        let connection: AirPlayConnection
        let host: String?
        var deviceID: String?
        var lastRequest = TakeoverPolicy.now()
        /// Has a live session (session SETUP done, no full TEARDOWN since).
        var hasSession = false
    }
    private var connections: [ObjectIdentifier: Peer] = [:]
    private let connectionQueue = DispatchQueue(label: "local.tutormirror.server.connections")
    private weak var manager: AirPlayManager?

    /// Called (once, from a network queue) if the listener can't be created or
    /// fails, e.g. the port is taken or Local Network access is denied.
    var onFailure: ((NWError) -> Void)?

    init(manager: AirPlayManager) {
        self.manager = manager
    }

    /// `loopbackOnly` is for the headless check: it talks to the server from
    /// this Mac only, so it never needs Local Network access.
    func start(port: UInt16, loopbackOnly: Bool = false) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if loopbackOnly {
                params.requiredInterfaceType = .loopback
            } else {
                PeerToPeer.current.apply(to: params)
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                logger.error("Invalid port: \(port)")
                onFailure?(.posix(.EINVAL))
                return
            }
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            logger.error("Failed to create listener: \(error)")
            onFailure?(error as? NWError ?? .posix(.EINVAL))
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Server listening on port \(port)")
            case .failed(let error):
                self?.logger.error("Server failed: \(error)")
                self?.onFailure?(error)
            case .waiting(let error):
                // Usually transient, except a Local Network privacy denial,
                // which won't resolve until the user changes the setting.
                self?.logger.warning("Server waiting: \(error)")
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    self?.onFailure?(error)
                }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        listener?.start(queue: .global(qos: .userInteractive))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        closeAllConnections()
    }

    /// Closes every control connection. Each connection still reports its own
    /// end of session to the manager: `close()` keeps it alive until it has.
    func closeAllConnections() {
        let closing = connectionQueue.sync {
            let all = connections.values.map(\.connection)
            connections.removeAll()
            return all
        }
        for conn in closing {
            conn.close()
        }
    }

    /// Pushes volume level to all active connections.
    func setVolume(_ volume: Float) {
        connectionQueue.sync {
            for peer in connections.values {
                peer.connection.setVolume(volume)
            }
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let host = Self.host(of: nwConnection.endpoint)
        let decision = connectionQueue.sync {
            TakeoverPolicy.onConnect(host: host, current: currentSender(), now: TakeoverPolicy.now(),
                                     allowTakeover: Settings.allowTakeover)
        }
        if decision == .replace {
            // Single-device mode: close any existing connections before accepting a new one.
            // This handles the case where an iPhone reconnects (rotation, lock/unlock) and
            // the old connection hasn't fully torn down yet.
            if connectionQueue.sync(execute: { !connections.isEmpty }) {
                logger.info("Closing existing connection(s) for new session")
                closeAllConnections()
            }
        } else {
            // Another device is mirroring. Let this one talk (/info, pairing)
            // but decide at its first SETUP, before it touches the shared ports.
            logger.info("Another device is mirroring; \(host ?? "?", privacy: .public) will be checked at SETUP")
        }

        let connection = AirPlayConnection(
            connection: nwConnection,
            manager: manager
        )
        let id = ObjectIdentifier(connection)
        connectionQueue.sync {
            connections[id] = Peer(connection: connection, host: host)
        }

        connection.onClose = { [weak self] in
            _ = self?.connectionQueue.sync {
                self?.connections.removeValue(forKey: id)
            }
        }
        connection.onActivity = { [weak self] activity in
            self?.note(activity, from: id)
        }
        if decision != .replace {
            connection.admit = { [weak self] deviceID, name, done in
                guard let self else { return done(true) }
                self.admit(id, deviceID: deviceID, name: name, done: done)
            }
        }

        connection.start()
        logger.info("New connection from \(String(describing: nwConnection.endpoint))")
    }

    // MARK: - Takeover protection

    /// The sender with a live session, if any. Must run on `connectionQueue`.
    private func currentSender() -> TakeoverPolicy.Sender? {
        connections.values
            .filter(\.hasSession)
            .max { $0.lastRequest < $1.lastRequest }
            .map { TakeoverPolicy.Sender(host: $0.host, deviceID: $0.deviceID, lastRequest: $0.lastRequest) }
    }

    private func note(_ activity: AirPlayConnection.Activity, from id: ObjectIdentifier) {
        connectionQueue.sync {
            guard connections[id] != nil else { return }
            switch activity {
            case .request:
                connections[id]?.lastRequest = TakeoverPolicy.now()
            case .sessionStarted(let deviceID):
                connections[id]?.hasSession = true
                connections[id]?.deviceID = deviceID
            case .sessionEnded:
                connections[id]?.hasSession = false
            }
        }
    }

    /// A connection that arrived while another device was mirroring sent its
    /// first SETUP. Either refuses it, or closes everyone else and calls
    /// `done(true)` once their listeners have had a moment to let go of the
    /// shared ports, so the new sender can bind them.
    private func admit(_ id: ObjectIdentifier, deviceID: String?, name: String?, done: @escaping @Sendable (Bool) -> Void) {
        let (decision, others) = connectionQueue.sync { () -> (TakeoverPolicy.Decision?, [AirPlayConnection]) in
            // Already closed by another sender that was let in first.
            guard let me = connections[id] else { return (nil, []) }
            let d = TakeoverPolicy.onSetup(host: me.host, deviceID: deviceID, current: currentSender(),
                                           now: TakeoverPolicy.now(), allowTakeover: Settings.allowTakeover)
            guard d == .replace else { return (d, []) }
            let others = connections.filter { $0.key != id }.map(\.value.connection)
            connections = connections.filter { $0.key == id }
            return (d, others)
        }

        guard let decision else { return done(false) }
        guard decision == .replace else {
            logger.notice("Refused \(name ?? "a device", privacy: .public): another device is mirroring")
            manager?.didRefuseTakeover(deviceName: name)
            done(false)
            return
        }
        logger.info("Letting \(name ?? "a device", privacy: .public) take over")
        guard !others.isEmpty else { return done(true) }
        let group = DispatchGroup()
        for conn in others {
            group.enter()
            conn.close { group.leave() }
        }
        group.notify(queue: .global(qos: .userInteractive)) {
            // Listener cancellation finishes asynchronously; give the ports a
            // moment to free up (a normal reconnect has the whole handshake).
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.25) { done(true) }
        }
    }

    /// "192.168.1.20" or "fe80::1%awdl0" — the sender's address, without the port.
    static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }
}
