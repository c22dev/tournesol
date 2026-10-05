//
//  BLEPeripheral.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import CoreBluetooth

final class BLEPeripheral: NSObject, MessageTransport {
    var onConnect: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onMessage: ((Envelope, UUID) -> Void)?

    private let localName: String
    private var manager: CBPeripheralManager!
    private var outbound: CBMutableCharacteristic?
    private var centrals: [UUID: CBCentral] = [:]
    private var inboxes: [UUID: LaneAssembler] = [:]
    private var outboxes: [UUID: Outbox] = [:]
    private var lastActivity: [UUID: ContinuousClock.Instant] = [:]
    private var fastLinks: Set<UUID> = []
    private var idleTimer: Timer?

    init(localName: String) {
        self.localName = localName
        super.init()
        #if os(iOS)
        let options: [String: Any] = [CBPeripheralManagerOptionRestoreIdentifierKey: "ch.cclerc.Tournesol.peripheral"]
        #else
        let options: [String: Any] = [:]
        #endif
        manager = CBPeripheralManager(delegate: self, queue: nil, options: options)
    }

    private func markActive(_ id: UUID) {
        lastActivity[id] = .now
        guard let central = centrals[id], fastLinks.insert(id).inserted else { return }
        manager.setDesiredConnectionLatency(.low, for: central)
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relaxIdleLinks() }
        }
    }

    private func relaxIdleLinks() {
        let now = ContinuousClock.now
        for id in fastLinks {
            guard let last = lastActivity[id], now - last > .seconds(4) else { continue }
            fastLinks.remove(id)
            if let central = centrals[id] {
                manager.setDesiredConnectionLatency(.high, for: central)
            }
        }
        if fastLinks.isEmpty {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    func send(_ message: Envelope, to peer: UUID, lane: Lane) {
        guard let central = centrals[peer], let data = try? MessageCodec.encode(message) else { return }
        let chunks = Framing.chunks(for: data, maxLength: central.maximumUpdateValueLength, lane: lane)
        outboxes[peer, default: Outbox()].enqueue(chunks, lane: lane)
        markActive(peer)
        flush()
    }

    private func flush() {
        guard let outbound else { return }
        var progressed = true
        while progressed {
            progressed = false
            for (id, central) in centrals {
                guard let chunk = outboxes[id]?.next else { continue }
                guard manager.updateValue(chunk, for: outbound, onSubscribedCentrals: [central]) else { return }
                outboxes[id]?.removeNext()
                progressed = true
            }
        }
    }

    private func publish() {
        let inbound = CBMutableCharacteristic(type: BLE.inbound, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let outbound = CBMutableCharacteristic(type: BLE.outbound, properties: [.notify], value: nil, permissions: [.readable])
        let service = CBMutableService(type: BLE.service, primary: true)
        service.characteristics = [inbound, outbound]
        self.outbound = outbound
        manager.removeAllServices()
        manager.add(service)
    }

    private func drop(_ id: UUID) {
        guard centrals.removeValue(forKey: id) != nil else { return }
        inboxes[id] = nil
        outboxes[id] = nil
        lastActivity[id] = nil
        fastLinks.remove(id)
        onDisconnect?(id)
    }
}

extension BLEPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            centrals.keys.forEach(drop)
            outboxes.removeAll()
            return
        }
        publish()
    }

    #if os(iOS)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {}
    #endif

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLE.service],
            CBAdvertisementDataLocalNameKey: localName,
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        drop(central.identifier)
        centrals[central.identifier] = central
        inboxes[central.identifier] = LaneAssembler()
        onConnect?(central.identifier)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        drop(central.identifier)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value else { continue }
            let id = request.central.identifier
            markActive(id)
            guard let payload = inboxes[id, default: LaneAssembler()].append(value),
                  let message = try? MessageCodec.decode(Envelope.self, from: payload)
            else { continue }
            onMessage?(message, id)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }
}
