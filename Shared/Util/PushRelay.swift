//
//  PushRelay.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import Foundation
import OSLog

nonisolated private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "Push")

nonisolated enum PushRelay {
    static let topic = "ch.cclerc.Tournesol.push-type.liveactivity"

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private static var endpoint: (url: URL, secret: String)? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "TournesolPushURL") as? String, !base.isEmpty,
              let secret = Bundle.main.object(forInfoDictionaryKey: "TournesolPushSecret") as? String, !secret.isEmpty,
              let url = URL(string: base)?.appending(path: "send")
        else { return nil }
        return (url, secret)
    }

    static var isConfigured: Bool { endpoint != nil }

    static func send(token: String, environment: String, payload: [String: Any], priority: Int) async {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["token": token, "environment": environment, "topic": topic, "pushType": "liveactivity", "priority": priority, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        do {
            let (response, status) = try await URLSession.shared.data(for: request)
            let code = (status as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                log.debug("push delivered")
            } else {
                log.error("push failed \(code): \(String(decoding: response, as: UTF8.self), privacy: .public)")
            }
        } catch {
            log.error("push error \(error.localizedDescription, privacy: .public)")
        }
    }

    static func payload(event: String, state: PlaybackState, device: DeviceInfo, artworkID: String?, tint: RGB?, alert: Bool) -> [String: Any]? {
        let content = LiveActivityContent(
            title: state.title ?? "Not Playing",
            artist: state.artist ?? "",
            isPlaying: state.isPlaying,
            elapsed: state.elapsed,
            duration: state.duration,
            timestamp: state.timestamp,
            artworkID: artworkID,
            outputName: state.output?.kind == .builtIn ? nil : state.output?.name,
            outputSymbol: state.output?.kind == .builtIn ? nil : state.output?.symbol,
            tint: tint,
            isConnected: true
        )
        guard let encoded = try? JSONEncoder().encode(content),
              let contentState = try? JSONSerialization.jsonObject(with: encoded)
        else { return nil }

        var aps: [String: Any] = [
            "timestamp": Int(Date.now.timeIntervalSince1970),
            "event": event,
            "content-state": contentState,
        ]
        if event == "start" {
            aps["attributes-type"] = "RemoteActivityAttributes"
            aps["attributes"] = ["deviceID": device.id, "deviceName": device.name, "deviceSymbol": device.kind.symbol]
        }
        if alert {
            aps["alert"] = ["title": state.title ?? device.name, "body": "Playing on \(device.name)"]
        }
        return ["aps": aps]
    }
}

nonisolated struct LiveActivityContent: Codable, Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var timestamp: Date
    var artworkID: String?
    var outputName: String?
    var outputSymbol: String?
    var tint: RGB?
    var isConnected: Bool
}
