# Nítido

Share a screen or a window to another Mac on the local network with crisp text, measured latency and ink on top. A native macOS prototype in Swift: ScreenCaptureKit, VideoToolbox, Network.framework and Metal, no dependencies.

![Viewer with ink from both sides](docs/screenshots/03-viewer.png)

## What it does

- Pick a window or display with the system picker; see it in a window at native Retina scale, 1:1, also after the shared window is resized or the display changes mode.
- Flip the codec loop: HEVC encode and decode on the same Mac with a quality slider and a before/after divider, so you can see exactly where small text starts to smear and how many milliseconds the codec costs.
- Pair a second Mac with a 4-digit code (TLS with a pre-shared key derived from it) and stream at 60 fps.
- Draw on the picture from either side; strokes fade after four seconds; ⌘Z undoes on both.
- Read the numbers: capture and display fps, capture-to-display or glass-to-glass latency, RTT, bitrate, drops.
- Pull the cable: both sides say Reconnecting, the viewer reconnects with backoff and recovers with a keyframe; the bitrate adapts to backlog and RTT.

![Welcome](docs/screenshots/01-welcome.png)

![The codec loop: the raw capture left of the divider, HEVC at the slider's bitrate right of it](docs/screenshots/02-share-loopback.png)

![The telemetry strip](docs/screenshots/04-strip.png)

## Measured on this Mac (MacBook Pro, Apple M5, macOS 26.5)

| Scenario | Result |
|---|---|
| Capture to display, raw, 3024×1964 | (fill in from the strip) ms |
| Codec loop at 20 Mbps, HEVC | codec (fill in) ms, total (fill in) ms |
| Two Macs on Wi-Fi, glass to glass (estimated) | (fill in) ms, RTT (fill in) ms |

Replace every "(fill in)" with the figures you read from the strip while recording the video, and add the four screenshots this README shows (`docs/screenshots/01-welcome.png`, `02-share-loopback.png`, `03-viewer.png`, `04-strip.png`; delete the link to any you skip, then delete `docs/screenshots/.gitkeep`). Do not publish the README with placeholders or broken images.

## How it works

One Swift package: five library targets and a thin app target that only wires them together.

- `NitidoCore` is pure Swift and fully unit-tested: the wire protocol (big-endian, a `u32 length · u8 type` header, 11 message types, payloads capped at 16 MiB, unknown types skipped by length), rolling one-second telemetry with p50/p95, a deterministic bitrate controller, the minimum-RTT clock-offset filter, ink geometry (Catmull-Rom smoothing, speed-to-width, fade, undo) and the HKDF pairing key.
- `NitidoCapture` wraps `SCContentSharingPicker` and `SCStream`: native pixel size, up to 60 fps, BGRA. Nítido's own windows are left out of the picker's choices, and a shared display is captured without the Nítido application, so its windows and sheets never appear in it. When the content changes size (a window resized, a display's mode changed), the stream restarts at the new size once it holds for 150 ms. Start, update and stop run one at a time, so a quick re-pick never races a stream being torn down.
- `NitidoCodec` wraps VideoToolbox in realtime mode with no frame reordering: HEVC Main, or H.264 High when there is no hardware HEVC encoder, a keyframe every 120 frames or on request.
- `NitidoLink` wraps Network.framework: a Bonjour `_nitido._tcp` listener and browser, one TLS connection per peer that carries both directions, a ping every 500 ms for RTT and an NTP-style clock offset taken from the fastest pong of the last 10 s, and the send backlog: bytes handed to the connection whose send has not completed yet. On the viewer a session reconnects after a drop with backoff (0.5, 1, 2 and 4 s, then every 5 s).
- `NitidoUI` holds the models and the windows. `VideoView` draws into a `CAMetalLayer` through Core Image: 1:1 when the window allows it, a Lanczos downscale when it does not, never an upscale. `FramePacer` decides when it draws. It keeps one frame, the newest, and one drawable in flight to start, because every drawable queued ahead of a frame delays it by a refresh and a source that changes at the display rate never drains that queue on its own. A frame that had to wait through a refresh is held back for one capture interval so a newer frame can replace it; the cap rises by one only when the display keeps starving. The held frame is drawn again after a resize or when the window comes back on screen, and that redraw never counts as a displayed frame, so the fps and latency figures stay honest. `InkOverlay` (an `InkCanvasView`) draws strokes as variable-width ribbons above the video; `TelemetryStrip` reads a snapshot four times a second.

Every stage drops work instead of queueing it: capture keeps only the newest frame, the encoder works on at most two frames at once and the newest frame it turns away goes in as soon as one finishes (unless a newer one got in first), the sharer skips non-key frames while the backlog is over four frames' worth and sends a keyframe once it drains, and the viewer draws only the newest decoded frame. Every 250 ms the bitrate controller reads the last second's median RTT and the backlog: it cuts 25% when the backlog passes two frames' worth or RTT climbs 40 ms above its 10-second minimum, adds 10% while both stay low, holds for 2 s after a cut, raises at most once every 2 s, and stays between 2 and 60 Mbps. The design spec and the implementation plan are in `docs/superpowers/`.

## Run it

Requires macOS 15 or later and Xcode 26 (Swift 6.2). From a clone:

```bash
swift scripts/make-icon.swift build   # optional: the app icon
scripts/bundle.sh                     # release build, build/Nítido.app, signed
open build/Nítido.app
```

`scripts/bundle.sh` signs with the first Apple Development identity in your keychain (Xcode, Settings, Accounts, Manage Certificates makes one with a free Apple ID). macOS grants Screen Recording to a signed bundle, so share from the bundle; `swift run nitido` is fine for a quick look at the windows. The fonts are in the repository; `scripts/fetch-fonts.sh` downloads them again. macOS asks for Screen Recording the first time you share. To try the network path on one Mac, launch the app twice (`open -n build/Nítido.app`).

From the zipped app (`Nitido-0.1-macOS15.zip`): unzip it and open `Nítido.app` once. The build is signed for development, not notarized, so macOS refuses it the first time: go to System Settings, Privacy & Security, and click Open Anyway (since macOS 15, right-click, Open no longer gets past this).

## Security

Pairing uses TLS 1.2 with a pre-shared key derived with HKDF-SHA256 from the 4-digit code and the sharer's name, over the ECDHE_PSK ciphersuite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`. Because of the ephemeral key exchange, someone who only records the network traffic cannot decrypt the session, not even later, after learning the code. A wrong code fails the handshake, and after three failed handshakes the sharer shows a new code, so nobody can work through the codes one by one, although each blind attempt still has a 1 in 10,000 chance. The real limit is the size of the code: an active attacker on the same network can pose as the sharer, test all 10,000 codes against the viewer's half of the handshake in milliseconds and relay the stream, and the rotation does not stop that, because that attack never fails a handshake. The 4-digit code is meant for a local network you trust (home, office), not for public Wi-Fi. The next step is a PAKE such as SPAKE2, where each active attempt tests a single guess, or a 128-bit secret shared by QR code; the details are in section 13 of the design spec.

## What's next

WebRTC with STUN/TURN for the open internet, AV1 where hardware allows, a region-diff pass so static text costs no bits, and audio.

## License

MIT. Fonts: Cormorant Garamond and Marcellus under the SIL Open Font License (see `Sources/NitidoUI/Fonts`).

Built by Ronald Rodríguez, RONAR AI, Turin, October 2026.
