//
//  TournesolApp.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import MediaPlayer
import SwiftUI

@main
struct TournesolApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .background {
                    SystemVolumeHost()
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

final class AppModel {
    static let shared = AppModel()
    let hub: Hub
    let liveActivity: LiveActivityController
    let volumeButtons: VolumeButtonForwarder

    private init() {
        let info = DeviceInfo.current
        let transport = CompositeTransport([BLECentral(), BLEPeripheral(localName: info.name)])
        hub = Hub(info: info, player: MusicPlayerSource(), transport: transport)
        hub.onRemoteArtwork = { key, data in
            if let small = ArtworkEncoding.thumbnail(from: data, maxPixelSize: 200, quality: 0.75) {
                ArtworkStore.save(small, id: key)
            }
        }
        liveActivity = LiveActivityController(store: hub.store)
        let hub = hub
        volumeButtons = VolumeButtonForwarder(store: hub.store) { hub.setControllerFocus($0) }
    }

    func shareNowPlaying(for duration: Duration = .seconds(15)) async {
        let store = hub.store
        let deadline = ContinuousClock.now + duration
        let connectDeadline = ContinuousClock.now + .seconds(5)
        while !store.remotes.contains(where: \.isConnected), ContinuousClock.now < connectDeadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        while ContinuousClock.now < deadline {
            hub.refreshLocal()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func rename(to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: DeviceInfo.nameKey)
        hub.rename(name)
    }
}

enum RemoteIntentRouter {
    static func perform(_ action: RemoteAction, on deviceID: String) async {
        let original = action == .togglePlayPause ? await LiveActivityController.flipPlayback(deviceID: deviceID) : nil
        let store = AppModel.shared.hub.store
        let deadline = Date.now.addingTimeInterval(5)
        while store.device(id: deviceID)?.isPaired != true, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let device = store.device(id: deviceID), device.isConnected, device.isPaired else {
            if let original { await LiveActivityController.restore(original, deviceID: deviceID) }
            return
        }
        switch action {
        case .togglePlayPause: device.send(.togglePlayPause)
        case .next: device.send(.next)
        case .previous: device.send(.previous)
        case .volumeUp: device.stepVolume(1)
        case .volumeDown: device.stepVolume(-1)
        }
        try? await Task.sleep(for: .milliseconds(400))
    }
}

extension DeviceInfo {
    static let nameKey = "deviceName"

    static var current: DeviceInfo {
        let kind: DeviceKind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        return DeviceInfo(id: DeviceIdentity.id, name: UserDefaults.standard.string(forKey: nameKey) ?? kind.displayName, kind: kind)
    }
}

private struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { VolumeService.shared.view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
