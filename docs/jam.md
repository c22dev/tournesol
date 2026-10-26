# Jam

One device leads; the others join. Everyone can add songs to the leader's queue, and any member can also play the music in step with the leader.

## Joining

- **Start a Jam** from the Jam button. Your paired devices that are connected (now or later) join automatically as remotes; turn on **Play here** for the ones that should play, or **Play on All Devices**.
- Unpaired devices nearby see "X's Jam is nearby" and can ask to join as guests. Guests can add songs and play along, but can't control playback. Their access lasts only for the Jam and is never stored.
- Devices find each other over Bluetooth, which carries everything day to day because it costs the least power. Wi-Fi (Bonjour `_tournesol._tcp`, peer-to-peer included) is brought up only while a Jam is active, for a device Bluetooth can't reach, or while the app is in front and a paired device is missing. It goes off again 60 s after it stops being needed.
- Jam messages go over Wi-Fi whenever that link exists, since Bluetooth's connection-interval jitter would spoil the clock estimate. Everything else stays on Bluetooth.

## Staying in step

- Each member estimates the leader's clock from ping/pong round trips, keeping the sample with the lowest delay.
- Targets account for output latency on both sides: `target = leader position + local latency - leader latency`.
- Drift goes through a median filter. Seeks aim ahead by a learned lead, and drift is corrected only when it is larger than how much seeks scatter (20–120 ms).

## Tune by Ear (Mac)

Reported output latency can be wrong, for example with Bluetooth or AirPlay. **Tune by Ear** fixes this using the Mac's microphone:

1. The other devices go quiet, then each one plays alone for 4 s while the Mac is muted.
2. The song jumps back, and the Mac plays the same passage alone.
3. GCC-PHAT cross-correlation (`AudioAlignment`) finds how far apart the takes really sound. After subtracting the drift each device already knew about, the remainder is saved as a latency trim for that device's current output (`LatencyTrim`).

On a MacBook with the iPhone next to it, the first run measured 48 ms; the second run measured 0 ms.
