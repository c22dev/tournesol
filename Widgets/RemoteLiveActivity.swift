//
//  RemoteLiveActivity.swift
//  TournesolWidgets
//
//  Created by Constantin Clerc on 05.10.2026.
//

import ActivityKit
import SwiftUI
import WidgetKit

private typealias ActivityState = RemoteActivityAttributes.ContentState

private extension RGB {
    func blended(with other: RGB, _ amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }

    var highlight: RGB { blended(with: RGB(red: 1, green: 1, blue: 1), 0.4) }
}

private extension ActivityState {
    var accent: RGB { tint ?? .sunflower }
}

struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            LockScreenRemote(context: context)
                .activityBackgroundTint(context.state.accent.scaled(0.3).color.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let deviceID = context.attributes.deviceID
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(id: state.artworkID, size: 50, radius: 13)
                        .shadow(color: state.accent.color.opacity(0.5), radius: 10)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .contentTransition(.identity)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(state.accent.highlight.color)
                        .opacity(state.isConnected ? 1 : 0.4)
                        .frame(width: 36, height: 50)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.headline)
                        Text(state.artist)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ActivityProgress(state: state)
                        ActivityControls(deviceID: deviceID, state: state, compact: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            } compactLeading: {
                ActivityArtwork(id: state.artworkID, size: 24, radius: 7)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .contentTransition(.identity)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(state.accent.highlight.color)
                    .opacity(state.isConnected ? 1 : 0.4)
            } minimal: {
                ActivityArtwork(id: state.artworkID, size: 24, radius: 12)
                    .overlay {
                        Circle().strokeBorder(state.accent.highlight.color, lineWidth: 1.5)
                    }
            }
            .keylineTint(state.accent.highlight.color)
        }
    }
}

private struct LockScreenRemote: View {
    let context: ActivityViewContext<RemoteActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ActivityArtwork(id: state.artworkID, size: 54, radius: 12)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                    Text(state.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    RouteLine(attributes: context.attributes, state: state)
                        .padding(.top, 3)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                ActivityProgress(state: state)
                ActivityControls(deviceID: context.attributes.deviceID, state: state)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .foregroundStyle(.white)
        .background { LockScreenBackground(state: state) }
    }
}

private struct LockScreenBackground: View {
    let state: ActivityState

    var body: some View {
        let tint = state.accent
        ZStack {
            LinearGradient(colors: [tint.scaled(0.62).color, tint.scaled(0.2).color], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = ArtworkStore.image(for: state.artworkID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .opacity(0.35)
            }
            RadialGradient(colors: [tint.highlight.color.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct RouteLine: View {
    let attributes: RemoteActivityAttributes
    let state: ActivityState

    var body: some View {
        HStack(spacing: 5) {
            if state.isConnected {
                Image(systemName: attributes.deviceSymbol)
                Text(attributes.deviceName)
                if let output = state.outputName {
                    Text("·")
                    Image(systemName: state.outputSymbol ?? "speaker.wave.2.fill")
                        .foregroundStyle(state.accent.highlight.color)
                    Text(output)
                        .layoutPriority(1)
                }
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("Reconnecting to \(attributes.deviceName)…")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }
}

private struct ActivityProgress: View {
    let state: ActivityState

    var body: some View {
        if state.duration > 0 {
            let start = state.timestamp.addingTimeInterval(-state.elapsed)
            let end = start.addingTimeInterval(state.duration)
            let pause = state.isPlaying ? nil : start.addingTimeInterval(min(state.elapsed, state.duration))
            HStack(spacing: 12) {
                Text(timerInterval: start...end, pauseTime: pause, countsDown: false)
                    .frame(width: 40, alignment: .leading)
                Group {
                    if state.isPlaying, end > .now {
                        ProgressView(timerInterval: start...end, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                    } else {
                        ProgressView(value: min(state.elapsed, state.duration), total: state.duration)
                    }
                }
                .progressViewStyle(.linear)
                .tint(.white)
                Text(timerInterval: start...end, pauseTime: pause, countsDown: true)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct ActivityControls: View {
    let deviceID: String
    let state: ActivityState
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            if !compact {
                control(.volumeDown, symbol: "speaker.fill", size: 14, opacity: 0.6)
            }
            Spacer(minLength: 0)
            control(.previous, symbol: "backward.fill", size: compact ? 19 : 20)
            Spacer(minLength: 0)
            Button(intent: RemoteActionIntent(deviceID: deviceID, action: .togglePlayPause)) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.identity)
                    .font(.system(size: compact ? 16 : 19, weight: .bold))
                    .foregroundStyle(state.accent.scaled(0.3).color)
                    .frame(width: compact ? 38 : 44, height: compact ? 38 : 44)
                    .background(.white, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            control(.next, symbol: "forward.fill", size: compact ? 19 : 20)
            Spacer(minLength: 0)
            if !compact {
                control(.volumeUp, symbol: "speaker.wave.3.fill", size: 14, opacity: 0.6)
            }
        }
        .padding(.horizontal, compact ? 44 : 0)
        .disabled(!state.isConnected)
        .opacity(state.isConnected ? 1 : 0.4)
    }

    private func control(_ action: RemoteAction, symbol: String, size: CGFloat, opacity: Double = 0.95) -> some View {
        Button(intent: RemoteActionIntent(deviceID: deviceID, action: action)) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(opacity))
                .frame(width: 44, height: compact ? 38 : 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct ActivityArtwork: View {
    let id: String?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image = ArtworkStore.image(for: id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [RGB.sunflower.highlight.color, RGB.sunflower.scaled(0.42).color], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}

#if DEBUG
private let previewAttributes = RemoteActivityAttributes(deviceID: "mac", deviceName: "Constantin's MacBook Pro", deviceSymbol: "laptopcomputer")

private let previewState = ActivityState(
    title: "Pink + White", artist: "Frank Ocean", isPlaying: true,
    elapsed: 71, duration: 184, timestamp: .now,
    artworkID: nil, outputName: "AirPods Pro", outputSymbol: "airpods.pro",
    tint: RGB(red: 0.75, green: 0.35, blue: 0.6), isConnected: true
)

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    RemoteLiveActivity()
} contentStates: {
    previewState
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    RemoteLiveActivity()
} contentStates: {
    previewState
}

#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    RemoteLiveActivity()
} contentStates: {
    previewState
}
#endif
