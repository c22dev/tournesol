//
//  PairingView.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

struct PairingView: View {
    let prompt: PairingPrompt

    var body: some View {
        VStack(spacing: 24) {
            PairingLink(prompt: prompt)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            ZStack {
                if let code = prompt.code {
                    PairingCode(code: code, isDimmed: prompt.phase == .cancelled, isConfirmed: prompt.phase == .paired)
                        .transition(.blurReplace)
                } else if prompt.phase != .cancelled {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .frame(height: 64)

            footer
                .frame(minHeight: 50)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .animation(.smooth, value: prompt.phase)
        .animation(.smooth, value: prompt.code)
        .sensoryFeedback(.success, trigger: prompt.phase == .paired) { _, paired in paired }
    }

    @ViewBuilder
    private var footer: some View {
        switch prompt.phase {
        case .paired:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: prompt.phase)
                .transition(.scale.combined(with: .opacity))
        case .cancelled:
            Label("Pairing cancelled", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        default:
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { prompt.respond(false) }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                Button {
                    prompt.respond(true)
                } label: {
                    Text("Codes Match")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(RGB.sunflower.color)
                .disabled(prompt.phase != .comparing)
            }
            .controlSize(.large)
        }
    }

    private var title: String {
        switch prompt.phase {
        case .paired: "Paired with \(prompt.deviceName)"
        default: "Pair with \(prompt.deviceName)"
        }
    }

    private var message: String {
        switch prompt.phase {
        case .exchanging: "Connecting..."
        case .comparing: "Make sure \(prompt.deviceName) shows the same code."
        case .waitingForPeer: "Waiting for \(prompt.deviceName) to confirm…"
        case .paired: "Your devices can now control each other."
        case .cancelled: "Nothing was shared."
        }
    }
}

private struct PairingLink: View {
    let prompt: PairingPrompt

    var body: some View {
        let isActive = prompt.phase == .exchanging || prompt.phase == .waitingForPeer || prompt.phase == .comparing
        HStack(spacing: 14) {
            DeviceGlyph(symbol: localSymbol, tint: .white.opacity(0.18))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let wave = isActive ? (sin(t * 4 - Double(index) * 0.9) + 1) / 2 : 1
                        Circle()
                            .fill(linkColor)
                            .frame(width: 5, height: 5)
                            .opacity(0.25 + 0.75 * wave)
                            .scaleEffect(0.7 + 0.5 * wave)
                    }
                }
            }
            .frame(width: 58)
            DeviceGlyph(symbol: prompt.deviceSymbol, tint: RGB.sunflower.color.opacity(0.45))
                .symbolEffect(.pulse, isActive: isActive)
        }
    }

    private var linkColor: Color {
        switch prompt.phase {
        case .paired: .green
        case .cancelled: .secondary
        default: RGB.sunflower.accent.color
        }
    }

    private var localSymbol: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
}

private struct DeviceGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .medium))
            .frame(width: 68, height: 68)
            .glassEffect(.regular.tint(tint), in: .circle)
    }
}

private struct PairingCode: View {
    let code: String
    let isDimmed: Bool
    let isConfirmed: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == " " {
                    Spacer().frame(width: 10)
                } else {
                    Text(String(character))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(width: 38, height: 52)
                        .glassEffect(.regular.tint(isConfirmed ? Color.green.opacity(0.35) : nil), in: .rect(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .opacity(isDimmed ? 0.3 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code \(code)")
    }
}

#if DEBUG
#Preview("Pairing") {
    let prompt = PairingPrompt(deviceName: "Constantin's MacBook Pro", deviceSymbol: "laptopcomputer")
    prompt.code = "482 913"
    prompt.phase = .comparing
    return PairingView(prompt: prompt)
        .preferredColorScheme(.dark)
}
#endif
