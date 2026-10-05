//
//  MacRootView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

struct MacRootView: View {
    let store: DeviceStore

    var body: some View {
        NavigationSplitView {
            DeviceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let device = store.selected {
                RemoteView(device: device)
            }
        }
        .environment(store)
    }
}

struct MenuBarRemote: View {
    let store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let device = store.selected {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.controllable) { candidate in
                            Button {
                                withAnimation(.smooth) { store.selectedID = candidate.id }
                            } label: {
                                Label(candidate.displayName, systemImage: candidate.info.kind.symbol)
                            }
                        }
                    } label: {
                        DeviceBadge(device: device, showsChevron: true)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()

                    Spacer()

                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            SettingsLink {
                                Image(systemName: "gearshape.fill")
                                    .frame(width: 30, height: 30)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("Settings")

                            Button {
                                openWindow(id: "main")
                                NSApp.activate()
                            } label: {
                                Image(systemName: "macwindow")
                                    .frame(width: 30, height: 30)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("Open Tournesol")
                        }
                    }
                }

                HStack(spacing: 14) {
                    ArtworkView(image: device.artwork, cornerRadius: 12, placeholderSymbol: device.state.hasTrack ? "music.note" : "sun.max.fill")
                        .frame(width: 68, height: 68)
                        .scaleEffect(device.state.isPlaying || !device.state.hasTrack ? 1 : 0.92)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: device.state.isPlaying)
                    VStack(alignment: .leading, spacing: 6) {
                        TrackInfoView(state: device.state, compact: true)
                        OutputRouteLabel(device: device)
                    }
                    TransferButton(device: device)
                }

                ScrubberView(state: device.state) { device.send(.seek($0)) }
                TransportControls(device: device, scale: 0.6)
                VolumeSlider(device: device)
            }
            .padding(18)
            .frame(width: 340)
            .foregroundStyle(.white)
            .background { BackdropView(device: device) }
            .overlay(alignment: .top) {
                if let transfer = store.transfer {
                    TransferBanner(status: transfer)
                        .padding(.top, 10)
                } else if !device.isConnected {
                    ReconnectingBanner()
                        .padding(.top, 10)
                }
            }
            .animation(.smooth, value: device.isConnected)
            .animation(.smooth, value: store.transfer == nil)
            .refreshingRemote(device)
            .environment(store)
        }
    }
}
