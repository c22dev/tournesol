//
//  PlayerComponents.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

extension RGB {
    func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    var accent: RGB { mixed(with: RGB(red: 1, green: 1, blue: 1), 0.35) }
}

extension RemoteDevice {
    var accent: RGB { tint ?? .sunflower }
}

struct ArtworkView: View {
    let image: PlatformImage?
    var cornerRadius: CGFloat = 16
    var placeholderSymbol = "music.note"

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder(symbol: placeholderSymbol)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
            }
    }
}

private struct ArtworkPlaceholder: View {
    let symbol: String

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                LinearGradient(
                    colors: [RGB.sunflower.mixed(with: RGB(red: 1, green: 0.9, blue: 0.5), 0.3).color, RGB.sunflower.scaled(0.42).color],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: side * 0.9)
                if side > 0 {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }
}

struct BackdropView: View {
    let device: RemoteDevice

    var body: some View {
        let tint = device.accent
        ZStack {
            Color.black
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.58, 0.48], [1, 0.4], [0, 1], [0.5, 1], [1, 1]],
                colors: Self.colors(for: tint),
                smoothsColors: true
            )
            if let artwork = device.artwork {
                Color.clear
                    .overlay {
                        Image(platformImage: artwork)
                            .resizable()
                            .scaledToFill()
                    }
                    .blur(radius: 50)
                    .opacity(0.45)
                    .clipped()
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .clear, location: 0.3), .init(color: .black.opacity(0.65), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .drawingGroup()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: device.tint)
    }

    private static func colors(for tint: RGB) -> [Color] {
        let glow = tint.mixed(with: RGB(red: 1, green: 0.95, blue: 0.85), 0.25)
        return [
            glow.scaled(0.95).color, tint.scaled(0.7).color, tint.scaled(0.45).color,
            tint.scaled(0.55).color, tint.scaled(0.32).color, tint.scaled(0.2).color,
            tint.scaled(0.22).color, tint.scaled(0.1).color, .black,
        ]
    }
}

struct DeviceBadge: View {
    let device: RemoteDevice
    var showsChevron = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.info.kind.symbol)
            Text(device.displayName)
                .fontWeight(.semibold)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct DeviceSwitcher: View {
    @Environment(DeviceStore.self) private var store
    var onShowAll: (() -> Void)?

    var body: some View {
        let selectedID = store.selected?.id
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(store.controllable) { device in
                            Button {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                    store.selectedID = device.id
                                }
                            } label: {
                                DeviceChip(device: device, isSelected: device.id == selectedID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(device.id == selectedID ? .isSelected : [])
                        }
                        if store.remotes.isEmpty, let onShowAll {
                            Button(action: onShowAll) { SearchingChip() }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
            .scrollIndicators(.hidden)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 14)
                }
            }

            if let onShowAll {
                Button(action: onShowAll) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                        .overlay(alignment: .topTrailing) {
                            if !store.unpaired.isEmpty {
                                Circle()
                                    .fill(RGB.sunflower.color)
                                    .frame(width: 9, height: 9)
                                    .offset(x: -6, y: 6)
                                    .transition(.scale)
                            }
                        }
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("All Devices")
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
        .animation(.smooth, value: store.unpaired.isEmpty)
    }
}

private struct DeviceChip: View {
    let device: RemoteDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: device.info.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)
            if isSelected {
                Text(device.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 190, alignment: .leading)
                    .transition(.blurReplace.combined(with: .opacity))
            }
            if !device.isConnected {
                ProgressView()
                    .controlSize(.mini)
            } else if device.state.isPlaying {
                EqualizerBars(isPlaying: true, color: device.accent.accent.color)
                    .frame(width: 12, height: 11)
            }
        }
        .padding(.horizontal, isSelected ? 14 : 11)
        .frame(height: 40)
        .frame(minWidth: 40)
        .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
        .contentShape(.capsule)
        .glassEffect(isSelected ? .regular.tint(device.accent.color.opacity(0.45)).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.displayName)
    }
}

private struct SearchingChip: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(RGB.sunflower.accent.color)
            Text("Find Devices")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .foregroundStyle(.white.opacity(0.85))
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct EqualizerBars: View {
    var isPlaying: Bool
    var color: Color = .white

    var body: some View {
        Image(systemName: "waveform")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

struct OutputRouteLabel: View {
    let device: RemoteDevice

    var body: some View {
        let output = device.state.output
        HStack(spacing: 6) {
            Image(systemName: output?.symbol ?? device.info.kind.symbol)
                .foregroundStyle(output.map { $0.kind == .builtIn } ?? true ? Color.white.opacity(0.6) : device.accent.accent.color)
            Text(output.map { $0.kind == .builtIn ? "\(device.info.kind.displayName) Speakers" : $0.name } ?? device.displayName)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(.smooth, value: output)
    }
}


struct TrackInfoView: View {
    let state: PlaybackState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            Text(state.title ?? "Not Playing")
                .font(compact ? Font.headline : Font.title2.weight(.bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(compact ? Font.subheadline : Font.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(state.track.signature)
        .transition(AnyTransition.push(from: .trailing).combined(with: .opacity))
        .animation(.smooth(duration: 0.4), value: state.track.signature)
    }

    private var subtitle: String {
        guard state.hasTrack else { return compact ? "Nothing playing" : "Start something in Music" }
        return [state.artist, compact ? nil : state.album].compactMap { $0 }.joined(separator: " · ")
    }
}

struct CapsuleSlider: View {
    let value: Double
    @Binding var dragValue: Double?
    var tint: Color = .white
    var onCommit: (Double) -> Void
    @State private var dragOrigin: (location: CGFloat, value: Double)?

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, dragValue ?? value))
            let isDragging = dragValue != nil
            Capsule()
                .fill(.white.opacity(isDragging ? 0.24 : 0.16))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tint.opacity(isDragging ? 1 : 0.85))
                        .frame(width: geometry.size.width * fraction)
                }
                .clipShape(.capsule)
                .frame(height: isDragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .scaleEffect(x: isDragging ? 1.025 : 1, anchor: .center)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let width = max(1, geometry.size.width)
                            let origin = dragOrigin ?? (gesture.startLocation.x, value)
                            dragOrigin = origin
                            dragValue = min(1, max(0, origin.value + (gesture.location.x - origin.location) / width))
                        }
                        .onEnded { gesture in
                            if gesture.translation == .zero {
                                dragValue = min(1, max(0, gesture.location.x / max(1, geometry.size.width)))
                            }
                            if let dragValue { onCommit(dragValue) }
                            dragValue = nil
                            dragOrigin = nil
                        }
                )
        }
        .frame(height: 26)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragValue == nil)
        .sensoryFeedback(.impact(weight: .light), trigger: dragValue.map { $0 <= 0 || $0 >= 1 } ?? false) { _, atEdge in atEdge }
    }
}

struct ScrubberView: View {
    let state: PlaybackState
    var onSeek: (TimeInterval) -> Void
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(state.duration, 1)
            let elapsed = dragValue.map { $0 * duration } ?? state.elapsed(at: context.date)
            VStack(spacing: 0) {
                CapsuleSlider(value: elapsed / duration, dragValue: $dragValue) { onSeek($0 * duration) }
                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(max(0, state.duration - elapsed)))
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(dragValue == nil ? 0.45 : 0.95))
                .animation(.smooth(duration: 0.2), value: dragValue == nil)
            }
        }
        .disabled(!state.hasTrack)
        .opacity(state.hasTrack ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Self.format(state.elapsed(at: .now)))
    }

    static func format(_ time: TimeInterval) -> String {
        Duration.seconds(time.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }
}

struct VolumeSlider: View {
    let device: RemoteDevice
    @State private var dragValue: Double?

    var body: some View {
        let volume: Double = dragValue ?? device.state.volume ?? 0
        let isAvailable = device.state.volume != nil
        HStack(spacing: 14) {
            Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 18)
                .onTapGesture { device.stepVolume(-1) }
            CapsuleSlider(value: device.state.volume ?? 0, dragValue: $dragValue) { device.setVolume($0) }
            Image(systemName: "speaker.wave.3.fill", variableValue: volume)
                .frame(width: 24)
                .onTapGesture { device.stepVolume(1) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white.opacity(dragValue == nil ? 0.55 : 0.9))
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.3)
        .onChange(of: dragValue) { _, value in
            if let value { device.setVolume(value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((volume * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            device.stepVolume(direction == .increment ? 1 : -1)
        }
    }
}

struct TransportControls: View {
    let device: RemoteDevice
    var scale: CGFloat = 1
    @State private var toggles = 0

    var body: some View {
        HStack(spacing: 30 * scale) {
            SkipButton(symbol: "backward.fill", size: 28 * scale, label: "Previous") { device.send(.previous) }

            Button {
                toggles += 1
                device.send(.togglePlayPause)
            } label: {
                Image(systemName: device.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34 * scale, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                    .offset(x: device.state.isPlaying ? 0 : 2 * scale)
                    .frame(width: 82 * scale, height: 82 * scale)
                    .contentShape(.circle)
            }
            .buttonStyle(PressableStyle())
            .glassEffect(.regular.tint(device.accent.color.opacity(0.5)).interactive(), in: .circle)
            .sensoryFeedback(.impact(weight: .medium), trigger: toggles)
            .accessibilityLabel(device.state.isPlaying ? "Pause" : "Play")

            SkipButton(symbol: "forward.fill", size: 28 * scale, label: "Next") { device.send(.next) }
        }
        .foregroundStyle(.white)
        .animation(.smooth, value: device.state.isPlaying)
    }
}

private struct SkipButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .symbolEffect(.bounce.byLayer, value: taps)
                .frame(width: size * 2, height: size * 2)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle(pressedBackground: true))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
    }
}

struct PressableStyle: ButtonStyle {
    var pressedBackground = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if pressedBackground {
                    Circle()
                        .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct StatusPill<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
    }
}

struct ReconnectingBanner: View {
    var body: some View {
        StatusPill(text: "Reconnecting…") {
            ProgressView()
                .controlSize(.small)
        }
    }
}

struct TransferBanner: View {
    let status: TransferStatus

    var body: some View {
        switch status.phase {
        case .moving:
            StatusPill(text: "Moving to \(status.targetName)…") {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .foregroundStyle(RGB.sunflower.accent.color)
            }
        case .failed:
            StatusPill(text: "Couldn't move to \(status.targetName)") {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

extension View {
    func refreshingRemote(_ device: RemoteDevice, every interval: Duration = .seconds(3)) -> some View {
        task(id: device.id) {
            guard !device.isLocal else { return }
            while !Task.isCancelled {
                device.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}

struct TransferButton: View {
    let device: RemoteDevice
    @Environment(DeviceStore.self) private var store

    var body: some View {
        let targets = store.transferTargets(from: device)
        let isEnabled = device.state.hasTrack && !targets.isEmpty && store.transfer == nil
        Menu {
            Section("Continue Playing On") {
                ForEach(targets) { target in
                    Button {
                        store.onTransfer(device, target)
                    } label: {
                        Label(target.displayName, systemImage: target.info.kind.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help("Move Playback to Another Device")
        .accessibilityLabel("Move Playback")
    }
}
