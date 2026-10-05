//
//  Previews.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

#if DEBUG
import SwiftUI

enum PreviewData {
    static var store: DeviceStore {
        let store = DeviceStore()
        let mac = device(name: "Constantin's MacBook Pro", kind: .macBook, title: "Pink + White", artist: "Frank Ocean", album: "Blonde", output: AudioOutput(name: "AirPods Pro", kind: .airPodsPro), colors: (.init(red: 0.95, green: 0.45, blue: 0.55), .init(red: 0.35, green: 0.2, blue: 0.6)))
        let phone = device(name: "iPhone", kind: .iPhone, isLocal: true, title: "Nights", artist: "Frank Ocean", album: "Blonde", playing: false, colors: (.init(red: 0.2, green: 0.6, blue: 0.9), .init(red: 0.05, green: 0.1, blue: 0.3)))
        let iPad = device(name: "iPad Pro", kind: .iPad, title: nil, artist: nil, album: nil, playing: false, colors: nil)
        store.devices = [phone, mac, iPad]
        store.selectedID = mac.id
        return store
    }

    private static func device(
        name: String, kind: DeviceKind, isLocal: Bool = false,
        title: String?, artist: String?, album: String?,
        playing: Bool = true, output: AudioOutput? = nil,
        colors: (RGB, RGB)?
    ) -> RemoteDevice {
        let device = RemoteDevice(info: DeviceInfo(id: UUID().uuidString, name: name, kind: kind), isLocal: isLocal)
        device.isPaired = true
        var state = PlaybackState()
        state.title = title
        state.artist = artist
        state.album = album
        state.duration = title == nil ? 0 : 184
        state.elapsed = title == nil ? 0 : 71
        state.isPlaying = playing && title != nil
        state.volume = 0.6
        state.output = output
        device.state = state
        if let colors {
            device.setArtwork(artwork(colors.0, colors.1), key: name)
        }
        return device
    }

    private static func artwork(_ top: RGB, _ bottom: RGB) -> Data? {
        let size = 320
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: top.red, green: top.green, blue: top.blue, alpha: 1), CGColor(red: bottom.red, green: bottom.green, blue: bottom.blue, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.fillEllipse(in: CGRect(x: 70, y: 70, width: 180, height: 180))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

#Preview("Remote") {
    let store = PreviewData.store
    RemoteView(device: store.selected!) {}
        .environment(store)
        .preferredColorScheme(.dark)
}

#Preview("Devices") {
    NavigationStack {
        DeviceSidebar(store: PreviewData.store)
    }
    .preferredColorScheme(.dark)
}
#endif
