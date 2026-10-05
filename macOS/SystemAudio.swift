//
//  SystemAudio.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import AudioToolbox
import CoreAudio

final class SystemAudio {
    var onChange: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var volumeListener: AudioObjectPropertyListenerBlock?

    init() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    var volume: Double? {
        get {
            var address = Self.volumeAddress
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return Double(value)
        }
        set {
            guard let newValue else { return }
            var value = Float32(min(1, max(0, newValue)))
            var address = Self.volumeAddress
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    var output: AudioOutput? {
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name = name?.takeRetainedValue() as String?
        else { return nil }

        var transportAddress = Self.address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport)

        let kind: AudioOutput.Kind = switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            AudioOutput.kind(forName: name, fallback: .bluetooth)
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        default: AudioOutput.kind(forName: name, fallback: .builtIn)
        }
        return AudioOutput(name: name, kind: kind)
    }

    private func attach() {
        var address = Self.volumeAddress
        if let volumeListener {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, volumeListener)
        }
        device = Self.defaultOutputDevice()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        volumeListener = listener
        onChange?()
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
