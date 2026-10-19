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

    static func defaultOutputDevice() -> AudioObjectID {
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

enum OutputLatency {
    /// Names the current output, so what tuning learns about it is kept apart from other outputs.
    static var route: String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(SystemAudio.defaultOutputDevice(), &address, 0, nil, &size, &uid) == noErr, let uid else { return "default" }
        return uid.takeRetainedValue() as String
    }

    /// How long sound takes to come out of this Mac's current output, as CoreAudio reports it.
    static var current: TimeInterval {
        let device = SystemAudio.defaultOutputDevice()
        func frames(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
        }
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0 else { return 0 }

        var total = frames(kAudioDevicePropertyLatency, of: device, scope: kAudioDevicePropertyScopeOutput)
            + frames(kAudioDevicePropertySafetyOffset, of: device, scope: kAudioDevicePropertyScopeOutput)
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamsSize = UInt32(0)
        if AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr, let stream = streams.first {
                total += frames(kAudioStreamPropertyLatency, of: stream, scope: kAudioObjectPropertyScopeGlobal)
            }
        }
        return Double(total) / rate
    }
}
