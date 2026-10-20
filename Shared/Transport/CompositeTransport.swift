//
//  CompositeTransport.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import Foundation

final class CompositeTransport: MessageTransport {
    var onConnect: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onMessage: ((Envelope, UUID) -> Void)?

    private struct Key: Hashable {
        let transport: Int
        let peer: UUID
    }

    private let transports: [MessageTransport]
    private var links: [Key: UUID] = [:]
    private var keys: [UUID: Key] = [:]

    init(_ transports: [MessageTransport]) {
        self.transports = transports
        for (index, transport) in transports.enumerated() {
            transport.onConnect = { [weak self] peer in
                guard let self else { return }
                if let stale = links.removeValue(forKey: Key(transport: index, peer: peer)) {
                    keys[stale] = nil
                    onDisconnect?(stale)
                }
                let link = UUID()
                links[Key(transport: index, peer: peer)] = link
                keys[link] = Key(transport: index, peer: peer)
                onConnect?(link)
            }
            transport.onDisconnect = { [weak self] peer in
                guard let self, let link = links.removeValue(forKey: Key(transport: index, peer: peer)) else { return }
                keys[link] = nil
                onDisconnect?(link)
            }
            transport.onMessage = { [weak self] message, peer in
                guard let self, let link = links[Key(transport: index, peer: peer)] else { return }
                onMessage?(message, link)
            }
        }
    }

    func isInitiator(_ link: UUID) -> Bool {
        guard let key = keys[link] else { return false }
        return transports[key.transport].isInitiator(key.peer)
    }

    func close(_ link: UUID) {
        guard let key = keys[link] else { return }
        transports[key.transport].close(key.peer)
    }

    func priority(of link: UUID) -> Int {
        guard let key = keys[link] else { return 0 }
        return transports[key.transport].priority(of: key.peer)
    }

    func medium(of link: UUID) -> Medium {
        guard let key = keys[link] else { return .bluetooth }
        return transports[key.transport].medium(of: key.peer)
    }

    func setWiFiEnabled(_ enabled: Bool) {
        transports.forEach { $0.setWiFiEnabled(enabled) }
    }

    func setLocalName(_ name: String) {
        transports.forEach { $0.setLocalName(name) }
    }

    func resumeAll() {
        transports.forEach { $0.resumeAll() }
    }

    func setScanning(_ scanning: Bool) {
        transports.forEach { $0.setScanning(scanning) }
    }

    func send(_ message: Envelope, to link: UUID, lane: Lane) {
        guard let key = keys[link] else { return }
        transports[key.transport].send(message, to: key.peer, lane: lane)
    }
}
