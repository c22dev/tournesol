//
//  DeviceViews.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

struct DeviceRow: View {
    let device: RemoteDevice
    var isSelected = false

    var body: some View {
        HStack(spacing: 13) {
            ArtworkView(image: device.artwork, cornerRadius: 10, placeholderSymbol: device.info.kind.symbol)
                .frame(width: 46, height: 46)
                .overlay(alignment: .bottomTrailing) {
                    if device.artwork != nil {
                        Image(systemName: device.info.kind.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .padding(4.5)
                            .background(.ultraThickMaterial, in: .circle)
                            .offset(x: 6, y: 6)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            if !device.isConnected {
                ProgressView()
                    .controlSize(.small)
            } else if device.state.isPlaying {
                EqualizerBars(isPlaying: true, color: device.accent.accent.color)
                    .frame(width: 16, height: 14)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, RGB.sunflower.color)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .animation(.smooth, value: isSelected)
    }

    private var subtitle: String {
        guard device.isConnected else { return "Reconnecting…" }
        guard device.state.hasTrack else { return "Not playing" }
        return [device.state.title, device.state.artist].compactMap { $0 }.joined(separator: " · ")
    }
}

struct DeviceSidebar: View {
    @Bindable var store: DeviceStore

    var body: some View {
        List(selection: $store.selectedID) {
            Section {
                ForEach(store.devices.filter(\.isLocal)) { device in
                    DeviceRow(device: device).tag(device.id as String?)
                }
            } header: {
                SectionHeader(title: "This Device")
            }
            Section {
                if store.remotes.isEmpty {
                    SearchingRow()
                } else {
                    ForEach(store.remotes) { device in
                        DeviceRow(device: device)
                            .tag(device.id as String?)
                            .contextMenu {
                                Button("Forget Device", systemImage: "minus.circle", role: .destructive) {
                                    store.onForget(device.id)
                                }
                            }
                    }
                }
            } header: {
                SectionHeader(title: "Your Devices")
            }
            if !store.unpaired.isEmpty {
                Section {
                    ForEach(store.unpaired) { device in
                        UnpairedRow(device: device) { store.onPair(device) }
                    }
                } header: {
                    SectionHeader(title: "Nearby")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Devices")
        .animation(.smooth, value: store.devices.map(\.id))
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

struct UnpairedRow: View {
    let device: RemoteDevice
    let onPair: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: device.info.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.info.name)
                    .font(.body.weight(.semibold))
                Text("Ready to pair")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Pair", action: onPair)
                .buttonStyle(.glassProminent)
                .tint(RGB.sunflower.color)
                .controlSize(.small)
                .fontWeight(.semibold)
        }
        .padding(.vertical, 5)
    }
}

struct SearchingRow: View {
    var body: some View {
        HStack(spacing: 13) {
            RadarPulse()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Looking for devices…")
                    .font(.body.weight(.semibold))
                Text("Open Tournesol nearby with Bluetooth on")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

struct RadarPulse: View {
    var color: Color = RGB.sunflower.color

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

struct DeviceGallery: View {
    let store: DeviceStore
    var onSelect: (RemoteDevice) -> Void
    var onPair: (RemoteDevice) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                GlassEffectContainer(spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(store.controllable) { device in
                            Button {
                                onSelect(device)
                            } label: {
                                DeviceCard(device: device, isSelected: device.id == store.selected?.id)
                            }
                            .buttonStyle(PressableCardStyle())
                            .contextMenu {
                                if !device.isLocal {
                                    Button("Forget Device", systemImage: "minus.circle", role: .destructive) {
                                        store.onForget(device.id)
                                    }
                                }
                            }
                        }
                    }
                }

                if store.remotes.isEmpty {
                    SearchingRow()
                        .padding(.horizontal, 4)
                }

                if !store.unpaired.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Nearby")
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(store.unpaired) { device in
                                UnpairedRow(device: device) { onPair(device) }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                if device.id != store.unpaired.last?.id {
                                    Divider().padding(.leading, 73)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .animation(.smooth, value: store.devices.map(\.id))
        }
    }
}

private struct DeviceCard: View {
    let device: RemoteDevice
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ArtworkView(image: device.artwork, cornerRadius: 12, placeholderSymbol: device.state.hasTrack ? "music.note" : device.info.kind.symbol)
                    .frame(width: 58, height: 58)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, RGB.sunflower.color)
                } else if !device.isConnected {
                    ProgressView()
                        .controlSize(.small)
                } else if device.state.isPlaying {
                    EqualizerBars(isPlaying: true, color: device.accent.accent.color)
                        .frame(width: 16, height: 14)
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Label(device.displayName, systemImage: device.info.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [device.accent.scaled(0.55).color.opacity(device.artwork == nil ? 0.15 : 0.55), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(RGB.sunflower.color, lineWidth: isSelected ? 2 : 0)
        }
        .animation(.smooth, value: isSelected)
    }

    private var subtitle: String {
        guard device.isConnected else { return "Reconnecting…" }
        guard device.state.hasTrack else { return "Not playing" }
        return device.state.title ?? ""
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
