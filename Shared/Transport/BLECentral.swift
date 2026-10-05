//
//  BLECentral.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import CoreBluetooth

final class BLECentral: NSObject, MessageTransport {
    var onConnect: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onMessage: ((Envelope, UUID) -> Void)?

    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var inbound: [UUID: CBCharacteristic] = [:]
    private var inboxes: [UUID: LaneAssembler] = [:]
    private var outboxes: [UUID: Outbox] = [:]
    private var ready: Set<UUID> = []
    private var suppressed: Set<UUID> = []
    private var wantsScanning = true

    override init() {
        super.init()
        #if os(iOS)
        let options: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: "ch.cclerc.Tournesol.central"]
        #else
        let options: [String: Any] = [:]
        #endif
        manager = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    func send(_ message: Envelope, to peer: UUID, lane: Lane) {
        guard ready.contains(peer), let peripheral = peripherals[peer], let data = try? MessageCodec.encode(message) else { return }
        let chunks = Framing.chunks(for: data, maxLength: peripheral.maximumWriteValueLength(for: .withoutResponse), lane: lane)
        outboxes[peer, default: Outbox()].enqueue(chunks, lane: lane)
        flush(peripheral)
    }

    private func flush(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let characteristic = inbound[id] else { return }
        while peripheral.canSendWriteWithoutResponse, let chunk = outboxes[id]?.next {
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            outboxes[id]?.removeNext()
        }
    }

    func isInitiator(_ peer: UUID) -> Bool { true }

    func close(_ peer: UUID) {
        guard let peripheral = peripherals[peer] else { return }
        suppressed.insert(peer)
        manager.cancelPeripheralConnection(peripheral)
    }

    func resumeAll() {
        guard !suppressed.isEmpty else { return }
        suppressed.removeAll()
        guard manager.state == .poweredOn else { return }
        peripherals.values.filter { $0.state == .disconnected }.forEach(connect)
    }

    func setScanning(_ scanning: Bool) {
        wantsScanning = scanning
        updateScanning()
    }

    private func updateScanning() {
        guard manager.state == .poweredOn else { return }
        if wantsScanning, !manager.isScanning {
            manager.scanForPeripherals(withServices: [BLE.service])
        } else if !wantsScanning, manager.isScanning {
            manager.stopScan()
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard !suppressed.contains(peripheral.identifier) else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices([BLE.service])
        } else {
            manager.connect(peripheral)
        }
    }

    private func reset(_ id: UUID) {
        inbound[id] = nil
        inboxes[id] = nil
        outboxes[id] = nil
        if ready.remove(id) != nil {
            onDisconnect?(id)
        }
    }
}

extension BLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            peripherals.keys.forEach(reset)
            return
        }
        central.retrieveConnectedPeripherals(withServices: [BLE.service]).forEach(connect)
        peripherals.values.forEach(connect)
        updateScanning()
    }

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
        }
    }
    #endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] == nil || peripheral.state == .disconnected else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLE.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset(peripheral.identifier)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset(peripheral.identifier)
        guard !suppressed.contains(peripheral.identifier) else { return }
        central.connect(peripheral)
    }
}

extension BLECentral: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLE.service }) else { return }
        peripheral.discoverCharacteristics([BLE.inbound, BLE.outbound], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == BLE.service }) else { return }
        reset(peripheral.identifier)
        peripheral.discoverServices([BLE.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLE.inbound: inbound[peripheral.identifier] = characteristic
            case BLE.outbound: peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard characteristic.uuid == BLE.outbound, characteristic.isNotifying, inbound[id] != nil, !ready.contains(id) else { return }
        ready.insert(id)
        onConnect?(id)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLE.outbound, let value = characteristic.value,
              let payload = inboxes[peripheral.identifier, default: LaneAssembler()].append(value),
              let message = try? MessageCodec.decode(Envelope.self, from: payload)
        else { return }
        onMessage?(message, peripheral.identifier)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush(peripheral)
    }
}
