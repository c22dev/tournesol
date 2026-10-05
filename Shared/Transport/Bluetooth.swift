//
//  Bluetooth.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import CoreBluetooth

enum BLE {
    static let service = CBUUID(string: "5E1A7F0C-2B4D-4C8E-9A61-7D3F0B9E1C20")
    static let inbound = CBUUID(string: "5E1A7F0C-2B4D-4C8E-9A61-7D3F0B9E1C21")
    static let outbound = CBUUID(string: "5E1A7F0C-2B4D-4C8E-9A61-7D3F0B9E1C22")
}

nonisolated enum Lane: UInt8, Sendable {
    case control, bulk
}

nonisolated enum Framing {
    static func chunks(for payload: Data, maxLength: Int, lane: Lane) -> [Data] {
        var framed = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(payload)
        let size = max(20, maxLength) - 1
        return stride(from: 0, to: framed.count, by: size).map {
            var chunk = Data([lane.rawValue])
            chunk.append(framed[$0..<min($0 + size, framed.count)])
            return chunk
        }
    }
}

nonisolated struct Outbox {
    private var control: [Data] = []
    private var bulk: [Data] = []

    var isEmpty: Bool { control.isEmpty && bulk.isEmpty }
    var next: Data? { control.first ?? bulk.first }

    mutating func enqueue(_ chunks: [Data], lane: Lane) {
        switch lane {
        case .control: control += chunks
        case .bulk: bulk += chunks
        }
    }

    mutating func removeNext() {
        if !control.isEmpty { control.removeFirst() } else if !bulk.isEmpty { bulk.removeFirst() }
    }
}

nonisolated struct LaneAssembler {
    private var lanes: [UInt8: FrameAssembler] = [:]

    mutating func append(_ chunk: Data) -> Data? {
        guard let lane = chunk.first else { return nil }
        return lanes[lane, default: FrameAssembler()].append(Data(chunk.dropFirst()))
    }
}

nonisolated struct FrameAssembler {
    private var buffer = Data()
    private var expected: Int?

    mutating func append(_ chunk: Data) -> Data? {
        buffer.append(chunk)
        if expected == nil, buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            expected = header.reduce(0) { $0 << 8 | Int($1) }
            buffer = Data(buffer.dropFirst(4))
        }
        guard let expected else { return nil }
        if expected > 4_000_000 {
            self = FrameAssembler()
            return nil
        }
        guard buffer.count >= expected else { return nil }
        let payload = Data(buffer.prefix(expected))
        buffer = Data(buffer.dropFirst(expected))
        self.expected = nil
        return payload
    }
}
