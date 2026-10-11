# Native queue (macOS)

Tournesol edits Music's own queue through private MediaRemote commands, sent with `osascript`. Each one is checked after it's sent and has a fallback, so a macOS update that breaks one degrades the app instead of breaking it. A feature that fails twice in a row is skipped for ten minutes.

| Action | Command | Fallback |
|---|---|---|
| Read Up Next | `MRNowPlayingController` queue request | the playlist Music plays from (no ids, so edits fall back too) |
| Play next / add to queue | 125 | Tournesol's own list |
| Remove / reorder / play a queued song | 129 / 130 / 131 | Tournesol's own list, or a library-search start |
| Start a catalog song | 122 | AppleScript, via library search or a `music://` URL |

Insert and start take `kMRMediaRemoteOptionSystemAppPlaybackQueueData`, a binary plist:
`{PQty: 3, PQst: [store ids], PQip: <play now>, PQri: 0, PQtr: 0, PQts: 0}`. Music aborts on any other shape, so only experiment against a throwaway session.

## After a macOS update

In a scratch Music session, launch a debug build with `-nativeSelfTest YES` and read the `SELFTEST` lines from the app's log. Each step says `native` or `fallback`. Add `-failNative '("edit","insert","start","read")'` (any subset) to force the fallbacks.

The planning logic is in `Shared/Util/NativeQueue.swift` and runs under `swift test`.
