//
//  MacPlayer.swift
//  Tournesol
//

import Foundation

/// Drives Music or Cider, whichever is playing. Commands only go to that one, so a closed Music is never launched.
final class MacPlayer: LocalPlayer {
    var onChange: (() -> Void)?
    let music = MusicAppSource()
    let cider = CiderSource()

    private enum Active: String { case music, cider }
    private static let lastUsedKey = "lastPlayer"
    private var active = Active.music
    /// While a song is being handed over, an idle player can't pull the choice back to the other one.
    private var pinnedUntil = ContinuousClock.now

    private var source: LocalPlayer { active == .music ? music : cider }

    var state: PlaybackState { source.state }
    var artwork: Artwork? { source.artwork }

    init() {
        // start with the one used last, so a handoff before anything plays goes where the user listens
        if UserDefaults.standard.string(forKey: Self.lastUsedKey) == Active.cider.rawValue, cider.isRunning {
            active = .cider
            music.isPassive = true
            cider.isPassive = false
        } else {
            cider.isPassive = true
        }
        music.onStreamUpdate = { [cider] info in cider.nudge(info) }
        music.onChange = { [weak self] in self?.changed(from: .music) }
        cider.onChange = { [weak self] in self?.changed(from: .cider) }
    }

    private func changed(from origin: Active) {
        reconsider()
        if origin == active { onChange?() }
    }

    private func reconsider() {
        let musicPlaying = music.state.isPlaying
        let ciderPlaying = cider.isRunning && cider.state.isPlaying
        let target: Active
        switch (musicPlaying, ciderPlaying) {
        case (true, false): target = .music
        case (false, true): target = .cider
        // idle: stay put, unless the current one has nothing and the other has a track
        default:
            if ContinuousClock.now < pinnedUntil { target = active }
            else if active == .music, !music.state.hasTrack, cider.isRunning, cider.state.hasTrack { target = .cider }
            else if active == .cider, !cider.isRunning || !cider.state.hasTrack, music.state.hasTrack { target = .music }
            else { target = active }
        }
        switchTo(target)
    }

    private func switchTo(_ target: Active) {
        guard target != active else { return }
        // the old player must not skip tracks on its own after the switch
        // switch first: release publishes, and that comes back here
        let previous = source
        active = target
        music.isPassive = target == .cider
        cider.isPassive = target == .music
        UserDefaults.standard.set(target.rawValue, forKey: Self.lastUsedKey)
        previous.perform(.release)
        onChange?()
    }

    /// A song handed over from another device plays in whichever player is in use, or else the one used last.
    private func routeIncomingTrack() {
        let musicPlaying = music.state.isPlaying
        let ciderPlaying = cider.isRunning && cider.state.isPlaying
        guard musicPlaying == ciderPlaying else { return }
        let preferred = Active(rawValue: UserDefaults.standard.string(forKey: Self.lastUsedKey) ?? "") ?? active
        // Cider only when it is there to answer; Music can always be started
        pinnedUntil = .now + .seconds(20)
        switchTo(preferred == .cider && cider.isRunning ? .cider : .music)
    }

    func perform(_ command: Command) {
        if case .loadTrack = command { routeIncomingTrack() }
        source.perform(command)
    }
    func refresh() { music.refresh(); cider.refresh() }
    func prepare(_ track: TrackReference) { source.prepare(track) }
    func upcomingTracks() async -> [TrackReference] { await source.upcomingTracks() }
}
