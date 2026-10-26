//
//  LANTransport.swift
//  Tournesol
//
//  Faster and longer-ranged than Bluetooth, but it costs much more power: devices find each other with Bonjour and
//  talk over TCP, on the same network or straight over peer-to-peer Wi-Fi. It only runs while the Hub asks for it.
//

import Foundation
import Network
import OSLog

nonisolated private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "LAN")

final class LANTransport: MessageTransport {
    static let serviceType = "_tournesol._tcp"
    private static let maxFrame = 4_000_000
    private static let maxPeers = 16

    var onConnect: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onMessage: ((Envelope, UUID) -> Void)?

    private let localID: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: Set<UUID> = []
    private var closedOnPurpose: Set<UUID> = []
    /// Peers that have sent at least one frame; an inbound connection that stays silent is dropped.
    private var heard: Set<UUID> = []
    private var outbound: [String: UUID] = [:]
    private var remoteIDs: [UUID: String] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var observers: [NSObjectProtocol] = []
    private var enabled = false

    init(localID: String, activationNotifications: [Notification.Name] = []) {
        self.localID = localID
        observers = activationNotifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        }
    }

    func priority(of peer: UUID) -> Int { 0 }
    func medium(of peer: UUID) -> Medium { .wifi }

    func setWiFiEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    func isInitiator(_ peer: UUID) -> Bool { remoteIDs[peer] != nil }

    func close(_ peer: UUID) {
        // closed on purpose because another link covers it, so it isn't dialled again
        closedOnPurpose.insert(peer)
        connections[peer]?.cancel()
    }

    func resumeAll() { start() }

    private func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        endpoints.removeAll()
        for peer in Array(connections.keys) { drop(peer) }
    }

    func send(_ message: Envelope, to peer: UUID, lane: Lane) {
        guard ready.contains(peer), let connection = connections[peer], let payload = try? MessageCodec.encode(message) else { return }
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }

    // MARK: Discovery

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Starts whatever isn't running, so it also recovers after the app was suspended.
    private func start() {
        guard enabled else { return }
        if listener == nil { startListener() }
        if browser == nil { startBrowser() }
    }

    private func startListener() {
        guard let listener = try? NWListener(using: Self.parameters()) else { return }
        listener.service = NWListener.Service(name: localID, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.connections.count < Self.maxPeers else { return connection.cancel() }
                self.adopt(connection, remoteID: nil)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state {
                    log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    self.listener?.cancel()
                    self.listener = nil
                    self.retry()
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                for change in changes {
                    switch change {
                    case .added(let result), .changed(old: _, new: let result, flags: _):
                        if case .service(let name, _, _, _) = result.endpoint, name != self?.localID {
                            self?.endpoints[name] = result.endpoint
                            self?.connectIfNeeded(to: name)
                        }
                    case .removed(let result):
                        if case .service(let name, _, _, _) = result.endpoint { self?.endpoints[name] = nil }
                    default: break
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failed(let error) = state {
                    log.error("browser failed: \(error.localizedDescription, privacy: .public)")
                    self.browser?.cancel()
                    self.browser = nil
                    self.retry()
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func retry() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.start()
        }
    }

    // MARK: Connections

    /// Of two devices, the one with the larger id connects, so a pair never ends up with two connections.
    private func connectIfNeeded(to name: String) {
        guard enabled, localID > name, outbound[name] == nil, connections.count < Self.maxPeers, let endpoint = endpoints[name] else { return }
        adopt(NWConnection(to: endpoint, using: Self.parameters()), remoteID: name)
    }

    private func adopt(_ connection: NWConnection, remoteID: String?) {
        let peer = UUID()
        connections[peer] = connection
        if let remoteID {
            remoteIDs[peer] = remoteID
            outbound[remoteID] = peer
        }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    log.info("connected \(remoteID == nil ? "inbound" : "outbound") peer \(peer.uuidString.prefix(8), privacy: .public)")
                    self?.ready.insert(peer)
                    self?.onConnect?(peer)
                    self?.receiveFrame(on: connection, peer: peer)
                case .failed, .cancelled:
                    self?.drop(peer)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, connections[peer] != nil, !heard.contains(peer) else { return }
            drop(peer)
        }
    }

    private func drop(_ peer: UUID) {
        guard let connection = connections.removeValue(forKey: peer) else { return }
        connection.cancel()
        heard.remove(peer)
        let wasClosedOnPurpose = closedOnPurpose.remove(peer) != nil
        let remoteID = remoteIDs.removeValue(forKey: peer)
        if let remoteID, outbound[remoteID] == peer { outbound[remoteID] = nil }
        if ready.remove(peer) != nil {
            log.info("disconnected peer \(peer.uuidString.prefix(8), privacy: .public)")
            onDisconnect?(peer)
        }
        if let remoteID, !wasClosedOnPurpose {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.connectIfNeeded(to: remoteID)
            }
        }
    }

    private func receiveFrame(on connection: NWConnection, peer: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[peer] === connection else { return }
                guard error == nil, let header, header.count == 4 else { return self.drop(peer) }
                let length = header.reduce(0) { $0 << 8 | Int($1) }
                guard length > 0, length <= Self.maxFrame else { return self.drop(peer) }
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                    MainActor.assumeIsolated {
                        guard let self, self.connections[peer] === connection else { return }
                        guard error == nil, let body, body.count == length else { return self.drop(peer) }
                        self.heard.insert(peer)
                        if let envelope = try? MessageCodec.decode(Envelope.self, from: body) {
                            self.onMessage?(envelope, peer)
                        }
                        self.receiveFrame(on: connection, peer: peer)
                    }
                }
            }
        }
    }
}
