<!-- Before publishing: work through "Before publishing" in docs/testing.md; its step 3, scripts/check-readme.sh, must pass before the repository goes public. -->

<p align="center">
  <img src="docs/screenshots/icon.png" width="128" height="128" alt="Nítido's icon: a thin gold italic N on a dark rounded square">
</p>

<h1 align="center">Nítido</h1>

<p align="center"><em>Share a screen to another Mac. Crisp text, measured latency, ink on top.</em></p>

<p align="center">
  <a href="#try-it-in-a-minute"><img src="https://img.shields.io/badge/macOS-15%2B-c9a86a?style=flat-square&amp;logo=apple&amp;logoColor=white&amp;labelColor=0e1015" alt="macOS 15 or later"></a>
  <a href="#how-it-works"><img src="https://img.shields.io/badge/Swift-6.2-c9a86a?style=flat-square&amp;logo=swift&amp;logoColor=white&amp;labelColor=0e1015" alt="Swift 6.2"></a>
  <a href="#testing"><img src="https://img.shields.io/badge/tests-443%20passing-62c37e?style=flat-square&amp;labelColor=0e1015" alt="443 tests passing"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-c9a86a?style=flat-square&amp;labelColor=0e1015" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/screenshots/loop.gif" width="900" alt="Twenty seconds of Nítido: the launch, a press on Share, the picture arriving with its code, a viewer pairing and its gold ring, a stroke from each side, the codec loop switched on and its divider dragged, the strokes fading, the quality lowered, and Stop back to Welcome">
</p>
<p align="center"><sub>One take through the render harness: the app's own screens and models, a synthetic desktop shared to a viewer over the loopback link, an arrow drawn where the harness clicks. Every value is under <a href="#motion">Motion</a>.</sub></p>

A native macOS app that shares a window or a screen to another Mac on the local network, with crisp text, measured latency and ink on top. Swift 6.2, ScreenCaptureKit, VideoToolbox, Network.framework and Metal; no third-party code.

I built it in a week in October 2026, as a prototype of the core loop of a pair-programming tool: capture, encode, send, decode and draw a screen, and measure each step.

## What it does

- Shares a window or a display picked with the system picker, shown at native Retina scale, 1:1, also after the window is resized or the display changes mode.
- Runs a codec loop on one Mac: HEVC encode and decode with a quality slider (2 to 60 Mbps) and a divider you drag between the raw capture and the decoded picture, with the codec's cost in milliseconds.
- Pairs a second Mac with a 4-digit code (TLS 1.2 with a pre-shared key derived from it) and streams to it at up to 60 fps.
- Lets both sides draw on the picture: your strokes in gold, the other side's in cream, a fade four seconds after the last point, and ⌘Z and ⌘⌫ on both sides. Each side sees the other's pointer as a gold dot with its name.
- Shows the numbers in a strip under the picture: capture or received fps, display fps, capture to display (one Mac) or glass to glass (two Macs), codec time, RTT, bitrate, drops, size and codec.
- Survives a lost network: both sides say Reconnecting, the viewer retries with backoff and recovers with a keyframe, and the bitrate follows the send backlog and the RTT.

## Screens

| <img src="docs/screenshots/01-welcome.png" width="380" alt="Welcome"> | <img src="docs/screenshots/05-pairing.png" width="380" alt="The viewer typing the sharer's 4-digit code (captured from the real window through the render harness)"> |
|:---:|:---:|
| **Welcome.** Share this Mac, or view another. | **Pairing.** The viewer types the 4-digit code the sharer shows. |
| <img src="docs/screenshots/02-share-loopback.png" width="380" alt="The codec loop: the raw capture left of the divider, HEVC at the slider's bitrate right of it"> | <img src="docs/screenshots/03-viewer.png" width="380" alt="The viewer paired over loopback, with ink from both sides and the sharer's pointer (captured from the real window through the render harness over a synthetic desktop)"> |
| **The codec loop.** Raw capture left of the divider, HEVC at the slider's bitrate right of it. | **The viewer.** Ink from both sides and the sharer's pointer (render harness, synthetic desktop). |

<p align="center"><img src="docs/screenshots/04-strip.png" width="820" alt="The telemetry strip"></p>
<p align="center"><sub><b>The telemetry strip.</b> Every figure under the picture, four times a second; the Measured table below was read from it.</sub></p>

## Motion

Every value here is a token in `Theme.Motion` ([`Theme.swift`](Sources/NitidoUI/Theme.swift)) or a constant beside the view it moves, and section 11 of the design spec reads the same numbers. Entrances run on `cubic-bezier(0.23, 1, 0.32, 1)`, movement on screen on `cubic-bezier(0.77, 0, 0.175, 1)`, exits are faster than entrances, and springs are kept for what feels alive (the connect ring) and what a drag can interrupt (the divider's dot).

| Moment | What moves | Values |
|---|---|---|
| Launch | The warmth rises, the card settles, the wordmark comes into focus, one gold glint crosses it | Warmth 480 ms; card from 0.98; wordmark from an 8 pt blur over 240 ms at 60 ms, the rest 40 ms apart; glint 760 ms from 440 ms on the system ease-in-out, once per launch |
| Press | Every button | Scale 0.97 over 120 ms on the strong ease-out (0.985 on wide rows), back the same way; ⏎ holds the gold button pressed 120 ms before it acts |
| Entrances | Buttons, chips, cards, panels, rows | From opacity 0 and scale 0.96 (never from 0) over 220 ms; wide rows rise 6 pt instead; siblings 40 ms apart; exits 120 ms, ease-out |
| The picture | The window grows from its top left corner; a cover over the picture fades | 300 ms growing, 260 ms shrinking; cover 220 ms, 40 ms after the first frame is on screen; the picture never scales, so its text is sharp from its first frame |
| After the picture | Strip, pairing panel, codec loop panel, code, notices | At 160, 200, 240, 280 and 320 ms |
| The code | Digit by digit | 40 ms apart, each rising 4 pt over 160 ms and settling from the gold highlight to gold over 360 ms |
| A viewer connects | The panel grows, the row arrives, a thin gold ring draws round it | Panel 240 ms; ring on a spring (duration 0.5, bounce 0.2), then down to a 1 pt hairline over 0.6 s; status dot on a spring (0.35, bounce 0.3) |
| Codec loop on | The panel unfolds, a light runs up the divider | Panel 240 ms, its rows 40 ms apart; light 220 ms at 40 ms; the strip's codec figure fades in at 80 ms over 180 ms |
| The divider | The line follows the pointer 1:1; the dot answers the grab | Dot to 1.3 on a spring (0.25, bounce 0.2) while held, 1.12 within 20 pt |
| The strip | Figures roll | 180 ms; a one-unit change waits half a second; each figure keeps the widest width it has shown, so nothing in the row jitters; capture, display and dropped show "·" until a full second has been counted, since the first second of a share or a picture is a partial count |
| Ink | Strokes fade | 4 s after the last point, over 600 ms; the other Mac sees an undo rewind over 180 ms |
| Reconnecting | The status dot breathes, the last frame dims | 1.2 s each way; 20 % |

Keyboard actions repeated often (⌘H, ⌘L, ⌘Z, ⌘⌫, Esc) change things at once, the window's size included. Loops over a live picture run on Core Animation, so they never tick the main thread. Reduce Motion takes away every scale, rise and slide, the window's animated resize, the ring, the shake, the glint and the breathing, and keeps the fades at the same timings. The GIF at the top is `NITIDO_RENDER=1 NITIDO_README=1 swift test --filter RenderGallery/testReadmeReel`.

## Try it in a minute

Built for macOS 15 or later; tested on macOS 26.5. The zip runs on Apple silicon only.

**From the zip.** Download `Nitido-0.2-macOS15.zip` from the [releases page](https://github.com/ronald13ai/nitido/releases), unzip it and open `Nítido.app`. It is signed for development, not notarized, so macOS blocks it the first time: open System Settings, Privacy & Security, and click Open Anyway. (Since macOS 15, Control-click and Open no longer gets past this.) In Terminal, `xattr -dr com.apple.quarantine Nítido.app` does the same.

**From source.** You need Xcode 26 (Swift 6.2) and an Apple Development signing identity: in Xcode, Settings, Accounts, Manage Certificates makes one with a free Apple ID.

```bash
git clone https://github.com/ronald13ai/nitido && cd nitido
swift test                            # 443 tests (and 9 more behind NITIDO_RENDER=1 and NITIDO_SOAK=1)
swift scripts/make-icon.swift build   # optional: the app icon
scripts/bundle.sh                     # release build: build/Nítido.app, signed, and its zip
open build/Nítido.app
```

macOS keeps a Screen Recording grant only for a signed bundle, so share from the bundle; `swift run nitido` is fine for a look at the windows. If Nítido says Screen Recording is off while its switch in System Settings is on, another copy of Nítido signed by someone else (the zip, then a build of your own, or the other way round) holds the grant: remove Nítido from the list with the minus button and add it again, or run `tccutil reset ScreenCapture ai.ronar.nitido`, then quit and reopen Nítido.

**On one Mac.** Click Share and pick a window. macOS asks for Screen Recording the first time; allow it, and choose Quit & Reopen if it offers that. Turn on the Codec loop switch (or press ⌘L) and drag the slider and the divider. For the network path, start a second copy with `open -n build/Nítido.app` (or `open -n Nítido.app` from the zip), click View in it (⌘⇧V), pick this Mac and type the code the first copy shows. The two copies talk over the same TLS link two Macs use.

**On two Macs.** Put both on the same network. Share on one, View on the other, pick the sharer by name and type its code. If macOS asks to let Nítido find devices on your local network, allow it on both Macs.

## Measured

Read from the telemetry strip on the 0.1 builds in the Build column: 168b191 and cae00eb on 2026-10-09, 6a87a21 on 2026-10-11. Releases 0.2 and 0.2.1 were not measured again: they changed the motion and the strip and added warm-ups for VideoToolbox and Core Image, while the capture, encode, link and draw code is otherwise the code measured. Sharer: MacBook Pro 14-inch, Apple M5, 120 Hz, macOS 26.5.2. Viewer: MacBook Air 13-inch, Apple M5, 60 Hz, macOS 26.5.1. Network: Wi-Fi 6 at 5 GHz.

| Scenario | Result | Build |
|---|---|---|
| Raw capture to display, window 1346×878 pt @2x (2692×1756 px) | 23 ms at 58 fps (21 ms on 168b191) | 6a87a21 |
| Raw capture to display, the whole display (2704×1756 px: the panel in its 1352×878 pt scaled mode) | 24 ms at 56 fps, shown fitted at 83% | 6a87a21 |
| Codec loop, HEVC at 2 Mbps, same window, text scrolling | codec 10 ms, capture to display 34 ms, real rate 1.5 Mbps, still text sharp (under the earlier cap of 1.5 times the rate per second; the last codec row is build 6a87a21 on a still picture) | 168b191 |
| Codec loop, HEVC at 20 Mbps, same window, text scrolling | codec 10 ms, capture to display 32 ms, real rate 7.7 Mbps | 6a87a21 |
| Codec loop, HEVC at 2 Mbps, same window, still | codec 5 ms, capture to display 27 ms | 6a87a21 |
| Two Macs, glass to glass (estimated) | 30 to 40 ms | cae00eb |
| Two Macs, RTT | 9 to 10 ms | 168b191 |

- Capture to display is exact on one Mac: the capture time and the presentation time come from the same host clock.
- Glass to glass across two Macs is an estimate: it uses an NTP-style clock offset from the fastest pong of the last 10 s, and the strip labels it "(est.)".
- The spec aimed for capture to display under 20 ms through the codec loop. I measured 34 ms there at 2 Mbps, and 21 ms without the codec. Glass to glass met its target of under 100 ms.
- At 2 Mbps the encoder kept under the rate (1.5 Mbps real), and still text stayed sharp. That was measured on build 168b191, under the earlier hard cap of 1.5 times the rate per second; the cap is now twice the rate over 2 s (spec 7), so the 2 Mbps scrolling row is to be measured again. Whether text stays sharp while it scrolls is still to be checked.
- Both two-Mac runs came before the fixes made after the evening run (the backlog rule, the keyframe limit, the pacer's cadence check). They were not measured again on build 6a87a21: the second Mac was not available on 2026-10-11, when the one-Mac rows above were taken. The first run (168b191) read 46 ms while the Air showed 33 of 58 fps (bug 2 below).

## How it works

One Swift package: five library targets, a thin app target, and a test-support target under `Tests/`.

**`NitidoCore`** has no Apple UI frameworks (Foundation and CryptoKit only), and all of it is unit-tested. It holds the wire format (big-endian, a 5-byte `u32 length · u8 type` header, 11 message types, payloads capped at 16 MiB, unknown types skipped by length), rolling one-second telemetry with p50 and p95, the bitrate controller, the sender's backlog rule (`BacklogPolicy`), the half-second keyframe limit (`KeyframeLimiter`), the minimum-RTT clock-offset filter, ink geometry (Catmull-Rom smoothing, speed to width, fade, undo) and the HKDF pairing key.

**`NitidoCapture`** wraps `SCContentSharingPicker` and `SCStream`: native pixel size, up to 60 fps, BGRA, cursor shown. Nítido's own windows are left out of the picker, and a shared display is captured without the Nítido app, so its windows and sheets never show in the picture. When the content changes size, the stream restarts at the new size once it has held for 150 ms. Start, update and stop run one at a time, so a quick re-pick never races a stream being torn down.

**`NitidoCodec`** wraps VideoToolbox in realtime mode with no frame reordering: HEVC Main, or H.264 High when there is no hardware HEVC encoder, with a keyframe every 120 frames or on request. The stream is tagged BT.709 with the sRGB transfer function, and the decoder hands its 4:2:0 pictures to Core Image, which converts them on the GPU as it draws.

**`NitidoLink`** wraps Network.framework: a Bonjour `_nitido._tcp` listener and browser, and one TLS connection per peer for both directions. A ping every 500 ms gives the RTT and the clock offset; a link with no pong for 3 s fails. The sharer publishes its port and IPv4 addresses in its TXT record, and the viewer dials up to two of them, then the Bonjour service, within 8 s. After a drop the viewer reconnects with backoff (0.5, 1, 2 and 4 s, then every 5 s), each time to where discovery says the sharer is now, and says the sharer is no longer sharing once it has left discovery and refused for 30 s. Connected through a published address, the viewer browses without peer-to-peer Wi-Fi, which would otherwise keep the radio hopping between channels; the sharer still advertises over it (see Limits). Both sides say hello with their protocol version first, and a mismatch ends the session with a message naming both versions.

**`NitidoUI`** holds the models and the windows. `VideoView` draws into a `CAMetalLayer` through Core Image: 1:1 when the window allows it, a Lanczos downscale when it does not, never an upscale. `FramePacer` keeps only the newest frame and as few drawables in flight as the display needs, because each drawable queued ahead of a frame delays it by a refresh ([`FramePacer.swift`](Sources/NitidoUI/FramePacer.swift) explains how many). `InkOverlay` draws strokes as variable-width ribbons over the video, a long stroke's finished part frozen in pieces so each new point costs the same, and `TelemetryStrip` reads a snapshot four times a second. Drawing the held frame again after a resize never counts as a displayed frame, so the fps and latency figures count only frames that reached the screen.

**`nitido`** is the app: one window, the menus, and a quit that asks first while something is live and tells the other Mac `bye` before the process ends (2 s at most). It has no logic of its own.

Every stage drops work instead of queueing it:

- Capture keeps only the newest frame.
- The encoder takes two frames at a time; of the frames it turns away, only the newest goes in next.
- A frame VideoToolbox drops counts as a drop; only ten real encode errors in a row stop the codec.
- The sharer skips deltas once its send backlog stays over 150 ms worth for 100 ms, or passes 1 s worth.
- The sharer forces at most one keyframe per half second per viewer; a new viewer's first goes at once.
- A message for a link that is not up is dropped, not queued.
- The viewer's decoder skips to the next keyframe once the oldest waiting frame is 50 ms old or eight wait.
- Only the newest decoded frame waits for the main thread.

One wait is left: frames that reach the viewer while its main thread is busy wait in the link's message stream. When they come in a burst, the decoder takes eight and skips the rest to the next keyframe.

Every 250 ms the bitrate controller reads the RTT (the last second's median, or how long an unanswered ping has waited, if that is longer) and the send backlog. It cuts 25% when the backlog passes two frames' worth, the RTT climbs 40 ms above its 10-second minimum, or the sender started skipping, then holds for 2 s (a new skip cuts even then). It adds 10% at most every 2 s while the backlog stays under one frame and the RTT within 15 ms of its minimum. It keeps between 2 and 60 Mbps and starts at 20 Mbps for 1080p, scaled by pixel count (45.6 Mbps for the 2692×1756 px window above). The design spec and the implementation plan are in `docs/design/`.

## What I found by testing on two Macs

On 2026-10-09 I ran Nítido on two Macs for the first time: the MacBook Pro sharing to the MacBook Air over Wi-Fi. These are the bugs that session found, and what I changed.

1. **A wrong code looked like a dead network.** The viewer waited out its 15 s deadline instead of saying "Wrong code", and the sharer counted one attempt as three or four failed handshakes, so one typo changed its code.\
   Fix: the viewer dials the addresses the sharer publishes, so the TLS failure comes back at once, and the sharer counts failures from one address less than 1 s apart as one attempt. That evening the viewer said "Wrong code" at once.
2. **The 60 Hz viewer showed 33 of 58 fps.** With one drawable in flight a frame costs two refreshes, so a 60 Hz panel showed every other frame; the ProMotion sharer starved the same way, because its screen said 120 Hz while presenting at 60.\
   Fix: two drawables in flight on a panel slower than twice the capture rate, a check of the real presentation cadence every second, and only the newest decoded frame waiting for the main thread. That evening the Air logged no more "fell behind" lines and showed glass to glass 30 to 40 ms.
3. **Colours were slightly off on the viewer.** The encoder set no colour tags, so the decoder read the capture's sRGB values as BT.709.\
   Fix: the stream is tagged BT.709 primaries and matrix with the sRGB transfer function. A test on one Mac went from up to 12 code values off to within 2. On the evening build, which had the tags, the Air's colours still looked slightly different by eye; the Digital Color Meter check ([docs/testing.md](docs/testing.md) item 27) will tell the codec apart from the two displays' profiles.
4. **The backlog rule turned into a keyframe slideshow.** While a long window scrolled, the sharer showed 58 fps and the viewer 10 to 48: one Wi-Fi burst tripped a skip, and the keyframe that ended it tripped the next, every 50 to 100 ms.\
   Fix: `BacklogPolicy` judges the backlog in time (150 ms worth for 100 ms, or 1 s worth at once) without the keyframe on its way, and `KeyframeLimiter` forces at most one keyframe per half second per viewer.
5. **VideoToolbox's drops failed the share.** Under that keyframe storm the realtime encoder dropped ten frames in a row, and the app counted each as a failure: "Video encoding keeps failing."\
   Fix: a dropped frame counts in the strip and is logged at most once a second; only ten real encode errors in a row stop the codec.
6. **The app crashed on a second share.** After one share stopped and another started, SwiftUI kept the ink canvas for the new share, but the canvas still held the old share's controller `unowned`, and its 30 Hz timer called into it after it was freed.\
   Fix: the canvas holds its controller weakly, follows the one it is handed, and ticks only while it is in a window. Tests reproduce the switch.

Fixes 4, 5 and 6, and the ProMotion half of 2, came after that session. Each has tests, but none has run on the Macs yet: items 16 and 24 to 26 of [docs/testing.md](docs/testing.md) check them.

## Security

Pairing uses TLS 1.2 with a pre-shared key derived with HKDF-SHA256 from the 4-digit code and the sharer's name. The only ciphersuite offered is `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, and a test checks it is the one negotiated.

- Someone who only records the traffic cannot decrypt it, not even after learning the code later, because of the ephemeral key exchange.
- A wrong code fails the handshake, and three wrong codes change the code. The sharer counts attempts, not handshakes: failures from one address less than a second apart are one attempt, up to four. So the code changes by the ninth failed handshake from one address at the latest, and a port scan or a connection cut short counts for nothing.
- At most eight connections prove the code at once, three from one address.
- Only the local network reaches the code: a connection over a VPN tunnel or cellular, or from a public address on none of the sharer's networks (a globally routable IPv6 address, say), is closed before its handshake and logged. Private addresses on another VLAN of the same network still get through.

What it does not protect against:

- Each blind guess has a 1 in 10,000 chance, and a host on the network can fail handshakes on purpose to keep the code changing, so that nobody can pair.
- An active attacker on the same network can pose as the sharer, test all 10,000 codes against the viewer's half of the handshake in milliseconds and relay the stream. The rotation does not help, because that attack never fails a handshake.

So the 4-digit code is for a network you trust (home, office), not public Wi-Fi. The next step is a PAKE such as SPAKE2, where each active attempt tests one guess, or a 128-bit secret shared by QR code; section 13 of the design spec has the details.

## Testing

`swift test` runs 443 XCTest tests, with no failures at the current commit (about three and a half minutes on an M5 once built); 9 more, the render gallery, its motion reel, the README's reel and the soak tests, run only with NITIDO_RENDER=1 (and NITIDO_MOTION=1 for the motion reel, which records every moment of the motion and cuts it into contact sheets, or NITIDO_README=1 for the README's GIF, one 20 s take through the moments) or NITIDO_SOAK=1.

- `NitidoCore` (60): wire round-trips and decoding fed byte by byte or a megabyte at a time, telemetry percentiles and the sparkline's time buckets, the bitrate controller, the backlog rule, the keyframe limit, the clock-offset filter, ink geometry and the pairing key.
- `NitidoCodec` (25): encode and decode loops on real VideoToolbox sessions, the warm-up that keeps the first session off the main thread, odd sizes kept 1:1, H.264's size limit, keyframe requests, the decoder's skip rule, colour tags, failure reporting and the rate cap on a dense scrolling page.
- `NitidoLink` (56): real TLS connections on this Mac (frames both ways, a wrong code, the negotiated ciphersuite, reconnects, a sharer gone for good), connections from outside the local network turned away before their handshake, the TXT record, the order of routes and discovery with and without peer-to-peer Wi-Fi.
- `NitidoCapture` (16): restarts after a resize or a display mode change, the serial start and stop, and the capture clock.
- `NitidoUI` (286): the frame pacer against a fake display, the motion's tokens, curves and state (staged entrances, the picture's cover waiting for its first frame, the code's stagger, the ring once per connection, the strip's hysteresis), the picture as drawn and Core Image's warm-up, the sharer and the viewer end to end over a real link with a stand-in capture source, colours through the codec, ink (a hostile peer's included, and a long stroke's cost per point), window sizes, menus, quitting and the sleep a live session holds off.

The picker and the Screen Recording grant, what reaches a real screen, and two real Macs are checked by hand: [docs/testing.md](docs/testing.md) is the checklist, one action and one expected result per item.

## Limits and what's next

- Local network only: discovery is Bonjour and there is no NAT traversal. Next: WebRTC with STUN/TURN for the open internet.
- One viewer at a time: a second viewer that proves the code takes the seat, and the first is told so; a viewer that reconnects by itself never takes it back from another Mac. The sharer knows a viewer by its address or its name, so two viewers with the same Mac name count as one. Next: a session token in the hello.
- The sharer keeps advertising over peer-to-peer Wi-Fi (AWDL) while a viewer is connected, so another viewer can still find it and take the seat, and a viewer it reaches only over AWDL can come back; leaving AWDL would mean replacing its listener mid-session. Its Wi-Fi may then split time with AWDL's channels and add jitter to the RTT and latency. The viewer leaves AWDL while connected through a published address. Still to measure on two Macs ([docs/testing.md](docs/testing.md) item 42); if it shows, the sharer will stop advertising over AWDL while the seat is taken.
- Through the Bonjour service alone (when no IPv4 address the sharer publishes routes, on an IPv6-only network say), one wrong code can count as two or three on the sharer and reads as no answer on the viewer. Next: publish the IPv6 addresses too and dial them one at a time.
- The 4-digit code is safe only on a trusted network (see Security). Next: SPAKE2 or a secret shared by QR code.
- The build is signed for development, not notarized.
- No audio, no remote control, no recording.
- Next for the picture: coding text regions at higher quality than photos, so small text stays sharp at low bitrates, and AV1 where the hardware encodes it.
- Still to check by hand: text at 2 Mbps while it scrolls, colours between two Macs with Digital Color Meter, and, on the Macs, fixes 4, 5 and 6 and the ProMotion half of 2.

## License

MIT. Fonts: Cormorant Garamond and Marcellus under the SIL Open Font License (see `Sources/NitidoUI/Fonts`).

Built by Ronald Rodríguez, RONAR AI, Turin, October 2026.
