//
//  VolumeService.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AVFoundation
import MediaPlayer
import OSLog
import UIKit

private let log = Logger(subsystem: "ch.cclerc.Tournesol", category: "Volume")

final class VolumeService {
    static let shared = VolumeService()

    let view: MPVolumeView
    private(set) var current: Double
    var onChange: (() -> Void)?
    var onButtonPress: ((Int) -> Bool)?

    private let session = AVAudioSession.sharedInstance()
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var lastReading: Float
    private var ownChanges: [(value: Float, expires: ContinuousClock.Instant)] = []
    private var observation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    private init() {
        view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.01
        AudioSessionQueue.shared.useAmbient(activate: UIApplication.shared.applicationState != .background)
        lastReading = session.outputVolume
        current = Double(lastReading)
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.handle(reading: value) }
        }
        observers = [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if !SilentAudio.isRunning {
                        AudioSessionQueue.shared.setActive(name == UIApplication.didBecomeActiveNotification)
                    }
                    self?.resync()
                }
            }
        }
    }

    private func resync() {
        lastReading = read()
    }

    func poll() {
        handle(reading: read())
    }

    func set(_ value: Double) {
        let value = Float(min(1, max(0, value)))
        ownChanges.append((value, .now + .seconds(3)))
        current = Double(value)
        write(value)
        onChange?()
    }

    private func handle(reading: Float) {
        guard abs(reading - lastReading) > 0.001 else { return }
        let previous = lastReading
        lastReading = reading

        ownChanges.removeAll { $0.expires < .now }
        if let index = ownChanges.firstIndex(where: { abs($0.value - reading) < 0.01 }) {
            ownChanges.remove(at: index)
            return
        }

        let raw = (reading - previous) * 16
        let steps = Int(raw.rounded()) != 0 ? Int(raw.rounded()) : (raw > 0 ? 1 : -1)
        log.debug("button press \(steps) (\(previous) → \(reading))")
        if onButtonPress?(steps) == true { return }
        current = Double(reading)
        onChange?()
    }

    private func read() -> Float {
        if UIApplication.shared.applicationState == .active {
            return session.outputVolume
        }
        if let value = mediaVolume() { return value }
        if musicPlayer.responds(to: NSSelectorFromString("volume")),
           let value = (musicPlayer.value(forKey: "volume") as? NSNumber)?.floatValue, (0...1).contains(value) {
            return value
        }
        return session.outputVolume
    }

    private func write(_ value: Float) {
        if view.window != nil, let slider = view.subviews.lazy.compactMap({ $0 as? UISlider }).first {
            slider.setValue(value, animated: false)
            slider.sendActions(for: .valueChanged)
        } else if musicPlayer.responds(to: NSSelectorFromString("setVolume:")) {
            musicPlayer.setValue(value, forKey: "volume")
        } else {
            log.error("no way to set volume")
        }
    }

    private lazy var systemController: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW)
        let selector = NSSelectorFromString("sharedAVSystemController")
        guard let type = NSClassFromString("AVSystemController") as? NSObject.Type, type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? NSObject
    }()

    private func mediaVolume() -> Float? {
        let selector = NSSelectorFromString("getVolume:forCategory:")
        guard let controller = systemController, controller.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector, UnsafeMutablePointer<Float>, NSString) -> ObjCBool
        let getter = unsafeBitCast(controller.method(for: selector), to: Getter.self)
        var volume: Float = -1
        guard getter(controller, selector, &volume, "Audio/Video" as NSString).boolValue, (0...1).contains(volume) else { return nil }
        return volume
    }
}
