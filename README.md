# Nítido

Share a screen or a window to another Mac on the local network with crisp text, measured latency and ink on top. A native macOS prototype in Swift: ScreenCaptureKit, VideoToolbox, Network.framework and Metal, no dependencies.

![Viewer with ink from both sides](docs/screenshots/03-viewer.png)

## What it does

- Pick a window or display with the system picker; see it in a window at native Retina scale, 1:1, also after the shared window is resized or the display changes mode.
- Flip the codec loop: HEVC encode and decode on the same Mac with a quality slider and a before/after divider, so you can see what each bitrate keeps and how many milliseconds the codec costs. The limit is honoured (the strip shows the real rate), small text that stands still stays sharp even at 2 Mbps (seen on 2026-10-09; text while it scrolls is still to be checked), and a low bitrate shows on photographic or fast-moving content.
- Pair a second Mac with a 4-digit code (TLS with a pre-shared key derived from it) and stream at 60 fps.
- Draw on the picture from either side; strokes fade after four seconds; ⌘Z undoes on both.
- Read the numbers: capture fps on the sharer and received fps on the viewer, display fps, capture-to-display or glass-to-glass latency, RTT, bitrate, drops.
- Pull the cable: both sides say Reconnecting, the viewer reconnects with backoff and recovers with a keyframe; the bitrate adapts to backlog and RTT.

![The codec loop at the quality slider's bitrates, 20 seconds](docs/screenshots/loop.gif)

![Welcome](docs/screenshots/01-welcome.png)

![The codec loop: the raw capture left of the divider, HEVC at the slider's bitrate right of it](docs/screenshots/02-share-loopback.png)

![The telemetry strip](docs/screenshots/04-strip.png)

## Measured on this Mac (MacBook Pro, Apple M5, macOS 26.5, build (fill in))

| Scenario | Result |
|---|---|
| Capture to display, raw, window 1346×878 @2x | 21 ms |
| Capture to display, raw, full display 3024×1964 | (fill in from the strip) ms |
| Codec loop at 2 Mbps, HEVC, window 1346×878 @2x | codec 10 ms, capture to display 34 ms |
| Codec loop at 20 Mbps, HEVC | codec (fill in) ms, total (fill in) ms |
| Two Macs on Wi-Fi, glass to glass (estimated) | (fill in) ms, RTT (fill in) ms |

## How it works

One Swift package: five library targets and a thin app target that only wires them together (plus a test-support target under Tests/).

- `NitidoCore` is pure Swift and fully unit-tested: the wire protocol (big-endian, a `u32 length · u8 type` header, 11 message types, payloads capped at 16 MiB, unknown types skipped by length), rolling one-second telemetry with p50/p95, a deterministic bitrate controller, the sender's backlog dropping rule and its limit of one forced keyframe per half second, the minimum-RTT clock-offset filter, ink geometry (Catmull-Rom smoothing, speed-to-width, fade, undo) and the HKDF pairing key.
- `NitidoCapture` wraps `SCContentSharingPicker` and `SCStream`: native pixel size, up to 60 fps, BGRA. Nítido's own windows are left out of the picker's choices, and a shared display is captured without the Nítido application, so its windows and sheets never appear in it. When the content changes size (a window resized, a display's mode changed), the stream is reconfigured for the new size once it holds for 150 ms. Start, update and stop run one at a time, so a quick re-pick never races a stream being torn down.
- `NitidoCodec` wraps VideoToolbox in realtime mode with no frame reordering: HEVC Main, or H.264 High when there is no hardware HEVC encoder, a keyframe every 120 frames or on request. The stream is tagged with the capture's colours (BT.709 primaries and matrix, the sRGB transfer function), and the decoder hands out its own 4:2:0 pictures, which Core Image turns into RGB on the GPU as it draws them. So the viewer shows the colours the sharer captured: flat colours match within 2 code values, and thin coloured strokes lose a little more to the 4:2:0 subsampling.
- `NitidoLink` wraps Network.framework: a Bonjour `_nitido._tcp` listener and browser, and one TLS connection per peer that carries both directions. A ping every 500 ms gives the RTT and an NTP-style clock offset, taken from the fastest pong of the last 10 s. Each link tracks its send backlog, the bytes handed to the connection whose send has not completed yet, with the keyframe on its way counted apart; a message given to a link that is not up is dropped, not queued. A link is ready only once both sides have said hello in the same protocol version, and another version ends the session with a message that names both. The viewer dials up to two of the IPv4 addresses the sharer publishes in its TXT record, then the Bonjour service, within 8 s: through the Bonjour service alone, between two Macs, the viewer was never told about a wrong code (the NitidoLink part of section 4 in the design spec has the details). After a drop the viewer reconnects with backoff (0.5, 1, 2 and 4 s, then every 5 s), each time to where discovery says the sharer is then.
- `NitidoUI` holds the models and the windows. `VideoView` draws into a `CAMetalLayer` through Core Image: 1:1 when the window allows it, a Lanczos downscale when it does not, never an upscale. `FramePacer` keeps only the newest frame and as few drawables in flight as the display needs, because each drawable queued ahead of a frame delays it by a refresh ([`FramePacer.swift`](Sources/NitidoUI/FramePacer.swift) has the rule for how many). `InkOverlay` draws strokes as variable-width ribbons above the video, and `TelemetryStrip` reads a snapshot four times a second. The held frame is drawn again after a resize or when the window comes back on screen, and that redraw never counts as a displayed frame, so the fps and latency figures stay honest.

Every stage drops work instead of queueing it.

- Capture keeps only the newest frame.
- The encoder holds at most two frames; the newest one it turned away goes in when one finishes, unless a newer one arrived (only then does it count as dropped).
- A frame VideoToolbox drops counts as dropped; only ten encoder failures in a row (an error or an empty frame) stop the codec.
- The sharer skips non-key frames once the backlog, not counting the keyframe on its way, stays over 150 ms worth for 100 ms, or at once over 1 s worth. It sends a keyframe when the backlog drains.
- At most one forced keyframe per half second per viewer; a new viewer's first keyframe goes at once.
- The viewer skips to the next keyframe once the oldest waiting frame is 50 ms old or eight are waiting, and only the newest decoded frame waits to be drawn.

One wait is left, on the viewer: frames that arrive while its main thread is busy wait in the link's stream, and when they are handed over in a burst the decoder takes eight and skips the rest to the next keyframe.

Every 250 ms the bitrate controller reads the last second's median RTT (or how long a pong still on its way has waited, if that is longer) and the backlog. It cuts 25% when the backlog passes two frames' worth or the RTT climbs 40 ms above its 10-second minimum, adds 10% at most every 2 s while both stay low, and stays between 2 and 60 Mbps. The design spec and the implementation plan are in `docs/superpowers/`.

## Run it

Requires macOS 15 or later and Xcode 26 (Swift 6.2). From a clone:

```bash
swift scripts/make-icon.swift build   # optional: the app icon
scripts/bundle.sh                     # release build: build/Nítido.app, signed, and its zip
open build/Nítido.app
```

`scripts/bundle.sh` signs with the first Apple Development identity in your keychain (Xcode, Settings, Accounts, Manage Certificates makes one with a free Apple ID). macOS grants Screen Recording to a signed bundle, so share from the bundle; `swift run nitido` is fine for a quick look at the windows. The fonts are in the repository; `scripts/fetch-fonts.sh` downloads them again. macOS asks for Screen Recording the first time you share. To try the network path on one Mac, launch the app twice (`open -n build/Nítido.app`).

From the zipped app (`Nitido-0.1-macOS15.zip`, on the [releases page](https://github.com/ronald13ai/nitido/releases)): unzip it and open `Nítido.app` once. The build is signed for development, not notarized, so macOS refuses it the first time: go to System Settings, Privacy & Security, and click Open Anyway (since macOS 15, right-click, Open no longer gets past this).

## Use it

1. On Mac A, click Share and pick a window or a display.
2. On Mac B, click View and pick Mac A from the list.
3. Type the 4-digit code Mac A shows.

## Security

Pairing uses TLS 1.2 with a pre-shared key derived with HKDF-SHA256 from the 4-digit code and the sharer's name, over the ECDHE_PSK ciphersuite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, the only one offered (a test checks it is the one negotiated). Because of the ephemeral key exchange, someone who only records the network traffic cannot decrypt the session, not even later, after learning the code. A wrong code fails the handshake, and after three wrong codes the sharer shows a new one. The sharer counts attempts, not handshakes, because one attempt can fail the handshake more than once: a failure on the keys less than a second after the last one from the same address counts as the same wrong code, up to four in a row. So the code changes after the ninth failed handshake the sharer sees from one address at the latest, and a port scan or a connection cut short counts for nothing. At most eight connections prove the code at once, three from one address.

What the pairing does not protect against: each blind attempt still has a 1 in 10,000 chance, and a host on the network can fail handshakes on purpose to keep the code changing, so that nobody can pair. The real limit is the size of the code: an active attacker on the same network can pose as the sharer, test all 10,000 codes against the viewer's half of the handshake in milliseconds and relay the stream, and the rotation does not stop that, because that attack never fails a handshake. The 4-digit code is meant for a local network you trust (home, office), not for public Wi-Fi. The next step is a PAKE such as SPAKE2, where each active attempt tests a single guess, or a 128-bit secret shared by QR code; the details are in section 13 of the design spec.

## What's next

WebRTC with STUN/TURN for the open internet, AV1 where hardware allows, a region-diff pass so the unchanged parts of a frame cost no bits, and audio.

## License

MIT. Fonts: Cormorant Garamond and Marcellus under the SIL Open Font License (see `Sources/NitidoUI/Fonts`).

Built by Ronald Rodríguez, RONAR AI, Turin, October 2026.
