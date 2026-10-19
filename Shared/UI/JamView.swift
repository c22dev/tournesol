//
//  JamView.swift
//  Tournesol
//

import SwiftUI

/// Starts a Jam in one tap, or opens the one in progress.
struct JamButton: View {
    @Environment(DeviceStore.self) private var store
    @State private var isPresented = false

    var body: some View {
        let isActive = store.jam != nil
        Button {
            if !isActive { store.onStartJam() }
            isPresented = true
        } label: {
            Label(isActive ? "In Jam" : "Jam", systemImage: "person.2.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color.yellow : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(isActive ? Color.yellow.opacity(0.18) : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .help(isActive ? "Open the Jam" : "Start a Jam: play together on several devices")
        .sheet(isPresented: $isPresented) { JamView() }
    }
}

/// The Jam at a glance on the main screen, or a nearby one to join.
struct JamBar: View {
    @Environment(DeviceStore.self) private var store
    @State private var isPresented = false

    var body: some View {
        Group {
            if let session = store.jam {
                HStack(spacing: 10) {
                    Button { isPresented = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.wave.2.fill").foregroundStyle(.yellow)
                            Text(session.isLeader ? "Your Jam" : "\(session.leaderName)'s Jam").fontWeight(.semibold)
                            Text("\(session.members.count) devices").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    if !session.isLeader {
                        Button(session.playsHere ? "Playing here" : "Play here", systemImage: session.playsHere ? "speaker.wave.2.fill" : "speaker.slash") {
                            store.onSetJamPlays(session.localID, !session.playsHere)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(session.playsHere ? Color.yellow : .white.opacity(0.75))
                    }
                }
            } else if let host = store.nearbyJams.first, let advert = host.jamAdvert {
                Button { isPresented = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.wave.2.fill").foregroundStyle(.yellow)
                        Text("\(advert.hostName)'s Jam is nearby").fontWeight(.semibold)
                        Text("Join").foregroundStyle(.yellow)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .opacity(store.jam != nil || !store.nearbyJams.isEmpty ? 1 : 0)
        .sheet(isPresented: $isPresented) { JamView() }
    }
}

/// Someone invites this device into a Jam, or asks to join ours.
struct JamPromptCard: View {
    let prompt: JamPrompt

    var body: some View {
        VStack(spacing: 12) {
            Label(title, systemImage: "person.2.wave.2.fill")
                .font(.headline)
                .multilineTextAlignment(.center)
            if prompt.isGuest {
                Text(prompt.kind == .request ? "As a guest they can add songs, not control playback." : "You'll join as a guest: you can add songs and play along.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            switch prompt.kind {
            case .invite:
                HStack {
                    Button("Not Now") { prompt.respond(false, false) }
                    Button("Join") { prompt.respond(true, false) }
                    Button("Join & Play Here") { prompt.respond(true, true) }
                        .buttonStyle(.borderedProminent)
                }
            case .request:
                HStack {
                    Button("Don't Allow") { prompt.respond(false, false) }
                    Button("Allow") { prompt.respond(true, false) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(18)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
    }

    private var title: String {
        switch prompt.kind {
        case .invite: "\(prompt.deviceName) invites you to a Jam"
        case .request: "\(prompt.deviceName) wants to join your Jam"
        }
    }
}

struct JamView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JamCoordinator.autoJoinKey) private var autoJoin = true
    @State private var invited: Set<String> = []
    @State private var searching = false
    @State private var showingQueue = false
    @State private var isTuning = false
    @State private var tuneResult: String?

    var body: some View {
        NavigationStack {
            Form {
                if let session = store.jam {
                    running(session)
                } else {
                    idle
                }
                Section {
                    Toggle("Join Jams from my devices automatically", isOn: $autoJoin)
                } footer: {
                    Text("Your paired devices join as remotes; you choose which ones play. Anyone else nearby has to ask first.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Jam")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    // MARK: Not in a Jam

    @ViewBuilder
    private var idle: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Play together", systemImage: "person.2.wave.2.fill").font(.headline)
                Text("Everyone in a Jam can add songs to one queue. Choose which devices play it, and they play in step for a bigger sound.")
                    .foregroundStyle(.secondary)
                Button("Start a Jam") { store.onStartJam() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
        if !store.nearbyJams.isEmpty {
            Section("Nearby") {
                ForEach(store.nearbyJams) { host in
                    HStack {
                        Label("\(host.jamAdvert?.hostName ?? host.info.name)'s Jam", systemImage: host.info.kind.symbol)
                        Spacer()
                        Button("Join") { store.onJoinJam(host, false) }
                        Button("Join & Play Here") { store.onJoinJam(host, true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: In a Jam

    @ViewBuilder
    private func running(_ session: JamSession) -> some View {
        let leader = session.isLeader ? store.devices.first(where: \.isLocal) : store.device(id: session.leaderID)

        Section {
            ForEach(session.members) { member in
                MemberRow(member: member, session: session) { store.onSetJamPlays(member.id, $0) }
            }
        } header: {
            Text(session.isLeader ? "Your Jam" : "\(session.leaderName)'s Jam")
        } footer: {
            Text("Each device that plays keeps in step with \(session.isLeader ? "this one" : session.leaderName), allowing for how long its speakers or headphones take.")
        }

        if session.isLeader, session.members.count > 1 {
            let everyonePlays = session.members.allSatisfy(\.plays)
            Section {
                Button(everyonePlays ? "Play Only Here" : "Play on All Devices", systemImage: everyonePlays ? "speaker.wave.1" : "speaker.wave.3.fill") {
                    store.onPlayOnAll(!everyonePlays)
                }
            }
        }

        if let tune = store.onTuneJam, session.playsHere, session.members.contains(where: { $0.id != session.localID && $0.plays }) {
            Section {
                Button(isTuning ? "Listening…" : "Tune by Ear", systemImage: "ear") {
                    isTuning = true
                    tuneResult = nil
                    Task {
                        tuneResult = await tune()
                        isTuning = false
                    }
                }
                .disabled(isTuning)
                if let tuneResult {
                    Text(tuneResult).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Listens with this Mac's microphone for about 15 seconds to line up how each device really sounds. Devices go quiet in turn, then the song jumps back a few seconds.")
            }
        }

        if session.isLeader {
            Section {
                let candidates = store.devices.filter { device in
                    !device.isLocal && device.isConnected && !session.members.contains { $0.id == device.id }
                }
                if candidates.isEmpty {
                    Text("No other devices nearby. A friend shows up here once they open Tournesol.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { device in
                    HStack {
                        Label(device.info.name, systemImage: device.info.kind.symbol)
                        Spacer()
                        if invited.contains(device.id) {
                            Text("Invited").foregroundStyle(.secondary)
                        } else {
                            Button(device.isPaired ? "Add" : "Invite as Guest") {
                                invited.insert(device.id)
                                store.onInviteToJam(device)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("Invite")
            }
        }

        if let leader {
            Section {
                Button("Add Songs", systemImage: "magnifyingglass") { searching = true }
                Button("Up Next", systemImage: "list.bullet") { showingQueue = true }
            }
            .sheet(isPresented: $searching) { SearchView(device: leader) }
            .sheet(isPresented: $showingQueue) { QueueView(device: leader) }
        }

        Section {
            Button(session.isLeader ? "End Jam" : "Leave Jam", role: .destructive) {
                store.onLeaveJam()
                invited = []
            }
        }
    }
}

private struct MemberRow: View {
    let member: JamMember
    let session: JamSession
    let setPlays: (Bool) -> Void

    private var isLeader: Bool { member.id == session.leaderID }
    private var isLocal: Bool { member.id == session.localID }
    /// The host decides for everyone; a member decides for itself.
    private var canChange: Bool { !isLeader && (session.isLeader || isLocal) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: member.kind.symbol)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).fontWeight(.medium)
                    if isLeader { Tag(text: "Host") }
                    if member.isGuest { Tag(text: "Guest") }
                    if isLocal { Tag(text: "This device") }
                }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canChange {
                Toggle(isOn: Binding(get: { member.plays }, set: setPlays)) {
                    Image(systemName: member.plays ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .help(member.plays ? "Stop playing on \(member.name)" : "Play on \(member.name) too")
            }
        }
        .lineLimit(1)
    }

    private var status: String {
        if isLeader { return "Plays · keeps the time" }
        guard member.plays else { return "Remote · can add songs" }
        guard let drift = session.drifts[member.id] else { return "Plays · getting in step…" }
        let milliseconds = Int((abs(drift) * 1000).rounded())
        return milliseconds <= 40 ? "Plays · in step" : "Plays · \(milliseconds) ms \(drift > 0 ? "ahead" : "behind")"
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}
