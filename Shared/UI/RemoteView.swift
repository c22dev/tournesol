//
//  RemoteView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

struct RemoteView: View {
    let device: RemoteDevice
    var onShowDevices: (() -> Void)?
    @Environment(DeviceStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            let isShort = geometry.size.height < 700
            let artworkSide = max(0, min(geometry.size.width - 56, geometry.size.height * (isShort ? 0.38 : 0.44), 460))
            VStack(spacing: 0) {
                if let onShowDevices {
                    DeviceSwitcher(onShowAll: onShowDevices)
                        .padding(.horizontal, -8)
                }
                Spacer(minLength: isShort ? 12 : 20)
                artwork
                    .frame(width: artworkSide, height: artworkSide)
                Spacer(minLength: isShort ? 16 : 28)
                VStack(spacing: isShort ? 12 : 20) {
                    HStack(alignment: .center, spacing: 14) {
                        TrackInfoView(state: device.state)
                        SearchButton(device: device)
                        TransferButton(device: device)
                    }
                    ScrubberView(state: device.state) { device.send(.seek($0)) }
                    TransportControls(device: device, scale: isShort ? 0.85 : 1)
                        .padding(.vertical, isShort ? 0 : 4)
                    VolumeSlider(device: device)
                    OutputRouteLabel(device: device)
                        .padding(.top, isShort ? 0 : 2)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, isShort ? 8 : 16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .background { BackdropView(device: device) }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let transfer = store.transfer {
                    TransferBanner(status: transfer)
                } else if !device.isConnected {
                    ReconnectingBanner()
                }
            }
            .padding(.top, 64)
        }
        .animation(.smooth, value: device.isConnected)
        .animation(.smooth, value: store.transfer?.phase)
        .animation(.smooth, value: store.transfer == nil)
        .refreshingRemote(device)
    }

    private var artwork: some View {
        let isPlaying = device.state.isPlaying || !device.state.hasTrack
        return ArtworkView(image: device.artwork, cornerRadius: 26, placeholderSymbol: device.state.hasTrack ? "music.note" : "sun.max.fill")
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
            }
            .scaleEffect(isPlaying ? 1 : 0.84)
            .animation(.spring(response: 0.55, dampingFraction: 0.68), value: isPlaying)
            .id(device.id)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .onTapGesture(count: 2) { device.send(.togglePlayPause) }
            .accessibilityLabel(device.state.hasTrack ? "Artwork" : "Nothing Playing")
    }
}
