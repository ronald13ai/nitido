# Nítido: design spec

Date: 2026-10-07 · Author: Ronald Rodríguez (RONAR AI) · Status: approved for planning

## 1. Purpose

Nítido is a small native macOS app that shares a screen or a window to another Mac on the local network with crisp text, low latency and drawing on top. It exists to answer one question with running software: can I capture, encode, transport and render a screen the way a pair-programming tool needs to, and measure it honestly.

Success in the first 60 seconds of a demo:

1. Pick a window with the system picker; it appears in a Nítido window at native Retina scale, text as sharp as the original.
2. A discreet telemetry strip shows capture fps, display fps and capture-to-display latency in milliseconds.
3. Toggle the local codec loop: the picture now goes through HEVC encode and decode on the same Mac; a quality slider shows where small text starts to smear and how many milliseconds the codec costs.
4. A second Mac (or a second Nítido instance) discovers the sharer by name, enters a 4-digit code, and shows the stream. Round-trip time and glass-to-glass latency appear in the strip.
5. Either side draws on the picture; strokes appear on both sides and fade after a few seconds. ⌘Z undoes.
6. Pull the network cable or kill one side: the other shows what happened, reconnects when it can, and the picture recovers with a fresh keyframe.

Targets (measured, not promised): 60 fps capture; capture-to-display under 20 ms in loopback on Apple silicon; glass-to-glass under 100 ms on Wi-Fi at the sharer's native resolution; stroke echo under 50 ms.

## 2. Non-goals

Internet (NAT traversal, STUN/TURN, WebRTC), audio, more than one viewer, remote keyboard and mouse control, recording, Windows or iOS. These are Pairio's product; Nítido is the proof of the core loop. The README lists WebRTC with STUN/TURN as the next step.

## 3. Platform and constraints

- macOS 15 or later. Liquid Glass materials on macOS 26 through `glassEffect`, `.ultraThinMaterial` fallback on 15.
- Swift 6 with strict concurrency, SwiftUI for windows and controls, AppKit and Metal where SwiftUI is not enough (the video view, the ink layer, the window chrome).
- Swift Package with library targets per module and one executable; a script assembles `Nítido.app` (Info.plist, icon, bundled fonts) and signs it with the Apple Development identity. Bundle id `ai.ronar.nitido`.
- Permissions: Screen Recording (macOS asks on first capture; the app explains it before the prompt) and Local Network (Bonjour).
- No third-party dependencies. Frameworks: ScreenCaptureKit, VideoToolbox, CoreMedia, Network, Metal, CoreImage, SwiftUI, AppKit.

## 4. Architecture

One package, six targets. Arrows point from a target to what it depends on.

```
nitido (app)  ->  NitidoUI  ->  NitidoCapture, NitidoCodec, NitidoLink  ->  NitidoCore
                                                                              ^
                                                              tests depend on Core, Link, Codec
```

### NitidoCore (pure Swift, no AppKit, fully unit-tested)
- `Wire`: message types and binary framing (section 6). `encode(Message) -> Data`, `Decoder.feed(Data) -> [Message]` tolerant of partial reads.
- `Telemetry`: rolling 1-second windows for fps, latency, RTT and bitrate; percentiles p50 and p95; exposes a `Snapshot` value for the HUD.
- `BitrateController`: deterministic policy (section 8). `update(rttMs:backlogBytes:frameAgeMs:) -> Int` (bits per second).
- `Ink`: `Stroke`, `StrokePoint`, Catmull-Rom smoothing, speed-to-width mapping, fade timing, undo stack. Geometry only.
- `Pairing`: 4-digit code generation and the HKDF derivation of the TLS pre-shared key from code + sharer name.

### NitidoCapture (ScreenCaptureKit)
- `CaptureSession`: wraps `SCContentSharingPicker` and `SCStream`. Emits `CapturedFrame { pixelBuffer, captureHostTime, contentRect, scale }` on an `AsyncStream`. Configured at native pixel size, 60 fps, BGRA, excluding Nítido's own windows (from the picker's choices; for a display, from the capture itself, by excluding the application), cursor shown.
- Handles picker cancel, stream stop by the system, display reconfiguration and a resized window (a new content size restarts the stream at that size and emits a new `videoConfig`).

### NitidoCodec (VideoToolbox)
- `VideoEncoder`: HEVC Main (H.264 High if HEVC hardware encode is unavailable), realtime, no frame reordering, keyframe every 120 frames or on request, `expectedFrameRate` 60, `averageBitRate` set from `BitrateController`. Emits `EncodedFrame { data (NAL units with 4-byte length prefixes, as VideoToolbox produces them), isKey, parameterSets?, captureHostTime, seq }`.
- `VideoDecoder`: builds the format description from parameter sets, decodes to `CVPixelBuffer`, emits `DecodedFrame { pixelBuffer, captureHostTime, seq }`. Flushes and rebuilds on a new `videoConfig`.
- Both drop work rather than queue it: the encoder always takes the newest captured frame; the decoder decodes on its own queue and judges itself behind by age, not by count: a delta is skipped only when the oldest frame still waiting has waited more than 50 ms on the decoder's clock (three frame intervals at 60 fps), or when eight frames wait, so frames handed over in a burst a few milliseconds apart are all decoded; a skip runs to the next keyframe, which is asked for, and a keyframe drops the frames still waiting before it; the renderer shows the newest.

### NitidoLink (Network.framework)
- `Advertiser` (sharer): `NWListener` over TCP with TLS PSK, Bonjour service `_nitido._tcp`, TXT record with display name, protocol version, the listener's port and the Mac's IPv4 addresses (Wi-Fi and Ethernet first).
- `Browser` (viewer): `NWBrowser` for `_nitido._tcp`; list of sharers updated live. A viewer dials up to two of the addresses the sharer published, off AWDL, those on one of the viewer's own networks (an interface that is up, by its address and netmask) before the others, each group in the order published, then the Bonjour service, within 8 s for the whole attempt; an address on none of the viewer's networks is still dialled, after those that are, so a sharer on another VLAN behind an mDNS reflector, or one with only a self-assigned 169.254 address, can be reached directly, and a desktop's Ethernet on another network, which it publishes first, does not hold up its Wi-Fi address; a sharer reached only over AWDL gets the Bonjour service after its silent addresses, with about 2 s of the deadline; an address that refuses, has no route or does not take the TCP connection within 4 s hands over to the next route at once, while a handshake already under way there is never cut for another route (amended 2026-10-10: the sharer may be checking it, and a second route would count a second wrong code); one that takes the connection and resets it ends the attempt with its reason, since the sharer may have failed a handshake there already and another route would count a second wrong code. Through the Bonjour service alone, between two Macs (2026-10-09), a wrong code failed the handshake four times on the sharer without a word to the viewer, which gave up after its deadline; the most likely reading of those logs is that Network.framework tried every resolved address in turn (IPv6 link-local, IPv4, AWDL). Every reconnect dials what discovery says about the sharer at that moment, since a sharer that relaunches or rotates its code listens on a new port; a reconnect that every published address refuses (nothing listens on the old port: the listener moved, which changes the code, or the sharer is gone) does not try the Bonjour service, so it fails no handshake there, and the next attempt dials what discovery reports by then (amended 2026-10-10). The sharer publishes its addresses again whenever they change.
- `Link`: one connection, both directions, `send(Message)` and an `AsyncStream<Message>`. Measures send backlog (bytes accepted by `send` whose completion has not fired). Ping every 500 ms. Reconnects with exponential backoff (0.5 s, 1 s, 2 s, max 5 s) while the user keeps the session open.

### NitidoUI (SwiftUI, AppKit, Metal)
- `VideoView`: `CAMetalLayer` drawing a `CVPixelBuffer` with 1:1 pixel mapping when the window's backing scale and size allow it, otherwise a high-quality Lanczos downscale through CoreImage. The window opens at the content's point size so the default is 1:1.
- `InkLayer`: `CALayer` above the video; one `CAShapeLayer` per stroke; local strokes in gold, remote strokes in cream; remote cursor as a gold dot with the peer's name.
- `TelemetryStrip`: the HUD (section 10).
- Windows: Welcome, Share, View (section 9).

### nitido (executable)
- `@main` SwiftUI `App`, activation policy `.regular`, menu with the shortcuts, the glue between modules. No logic of its own beyond wiring.

## 5. Data flow

Share side: picker → `CaptureSession` → (loopback off) `VideoEncoder` → `Link.send(videoFrame)`; strokes from `InkLayer` → `Link.send(stroke)`; incoming strokes and cursor → `InkLayer`.

Loopback (share side, no viewer needed): `CaptureSession` → `VideoEncoder` → `VideoDecoder` → `VideoView`, with the raw frame kept for the before/after comparator (split view with a draggable divider).

View side: `Browser` → user picks a sharer and enters the code → `Link` → `videoConfig` builds the `VideoDecoder` → `VideoView`; local strokes go back over the same `Link`.

Clocks: inside one Mac, `captureHostTime` compared with the display time gives exact capture-to-display latency. Across Macs, the viewer estimates the sharer's clock offset from ping/pong (offset = ((t1 - t0) + (t2 - t3)) / 2, like NTP) and reports glass-to-glass latency as an estimate with the RTT alongside it; the HUD labels it as estimated.

## 6. Wire protocol

Byte order big-endian. Every message: `u32 length` (payload bytes, excluding the 5-byte header) · `u8 type` · payload. Maximum payload 16 MiB; anything larger closes the link as a protocol error.

| type | name | payload |
|---|---|---|
| 1 | hello | u16 protocolVersion · u8 role (1 share, 2 view) · utf8 name (u8 length prefix) · u16 pixelWidth · u16 pixelHeight · f32 scale |
| 2 | videoConfig | u8 codec (1 hevc, 2 h264) · u16 width · u16 height · parameter sets (u8 count, each u16 length + bytes) |
| 3 | videoFrame | u32 seq · u64 captureHostTimeNs · u8 isKey · bytes (length-prefixed NAL units) |
| 4 | stroke | u32 strokeId · u8 phase (1 begin, 2 append, 3 end) · u8 r,g,b · f32 baseWidth · u16 pointCount · points (f32 x, f32 y normalized 0..1, f32 pressure, u32 tMs) |
| 5 | cursor | f32 x · f32 y normalized · u8 visible |
| 6 | ping | u32 id · u64 tNs |
| 7 | pong | u32 id · u64 originalTNs · u64 replyTNs |
| 8 | keyframeRequest | empty |
| 9 | undo | u32 strokeId |
| 10 | clear | empty |
| 11 | bye | u8 reason |

`hello` is the first message in both directions, sent the moment TLS is up; a link is ready only once the other side's `hello` speaks this side's version, so a Mac on another version never takes the viewer's seat, and mismatched versions end with `bye(1)` and a final message naming both (the viewer does not reconnect). The sharer sends `hello` again when the capture's size or scale changes. `bye` reasons: 0 the session ended (Esc, Back, Stop, quit), 1 protocol mismatch, 2 the sharer stopped capturing and listening (a failure, or Stop Sharing in the menu bar). Unknown types are skipped by length, so the protocol can grow.

## 7. Codec settings

`kVTCompressionPropertyKey_RealTime` true, `AllowFrameReordering` false, `ProfileLevel` HEVC Main or H.264 High, `MaxKeyFrameInterval` 120, `ExpectedFrameRate` 60, `AverageBitRate` from the controller, `DataRateLimits` set to 1.5x the average per second, `PrioritizeEncodingSpeedOverQuality` false (text matters more than speed here; the controller protects latency through bitrate and dropping). Hardware encoder required; if `VTCopySupportedPropertyDictionary` reports no hardware HEVC, fall back to H.264 and say so in the HUD.

## 8. Bitrate controller and dropping policy

Inputs every 250 ms: RTT p50 of the last second, send backlog in bytes, whether the sender started skipping frames for the backlog since the last update, and the age of the newest frame the viewer reported (carried in pong as an extra u32 when available, else unknown). The backlog is the one the dropping rule below judges: it leaves out the keyframe on its way (the oldest one still being sent), since a keyframe is one burst the encoder makes on purpose; the keyframes and frames queued behind it count, so a stream of keyframes is a backlog like any other (amended 2026-10-09: leaving out every keyframe in flight let a viewer that kept asking for keyframes grow the backlog with neither the ceiling nor the controller seeing it).

- Baseline RTT: minimum RTT seen in the last 10 s.
- Decrease by 25% if backlog exceeds two frames' worth of bytes at the current rate, or RTT exceeds baseline + 40 ms, or the sender started skipping frames. After a decrease, hold for 2 s; a skip cuts even within the hold: the backlog lasted 100 ms over 150 ms worth, or passed a second's worth (amended 2026-10-09).
- Increase by 10% every 2 s while backlog stays under one frame and RTT stays within baseline + 15 ms.
- Bounds: 2 Mbps to 60 Mbps; initial 20 Mbps at 1080p-class sizes, scaled by pixel count (45.6 Mbps for a 1346×878 pt window at 2x, 2692×1756 px).
- Loopback mode ignores network inputs and uses the slider value directly.

Dropping: the encoder keeps only the newest captured frame; the sender skips non-key frames once the backlog has stayed over 150 ms worth at the current rate (four frames' worth if that were more) for 100 ms, every reading in between over it too, or at once when it is over a second's worth; from then on it skips every delta until a keyframe has gone out, asks for that keyframe once the backlog is under one frame's worth (again only if none went out within a second), and for 500 ms after it only a backlog over a second's worth starts another skip; for 500 ms after the controller cuts the rate, the threshold and the ceiling are judged at the rate before the cut, so a cut, which shrinks them by a quarter, does not trip a skip (and a second cut) on an unchanged backlog by itself (amended 2026-10-09: 684 kB is 120 ms worth at 45.6 Mbps and 160 ms worth at 34.2); the viewer displays only the newest decoded frame; on reconnect or decode error the viewer sends `keyframeRequest`. The sharer forces at most one keyframe per 500 ms for a viewer: its requests, the keyframe after a drain and the one for a viewer that comes back from the same address share that limit, the first for a new viewer goes at once, and one asked for inside the 500 ms goes when they are up unless a keyframe went out meanwhile (amended 2026-10-09: on the evening two-Mac test forced keyframes came every 50 to 100 ms, and VideoToolbox dropped ten frames in a row under them). Nothing ever grows a queue.

Amended 2026-10-09 from "skips non-key frames while backlog exceeds four frames' worth", judged at each frame. On the second two-Mac test (2692×1756 HEVC from a MacBook Pro over Wi-Fi 6 at 5 GHz to a MacBook Air, RTT 9 to 10 ms, a 120-line TextEdit window scrolled with the trackpad) that rule tripped on single readings: a backlog of 144 kB, over four frames' worth, so the rate had already been cut under 17.3 Mbps from the initial 45.6, at least four times (about 80 ms of traffic at 14.4 Mbps), drained 17 ms later, and the keyframe sent then filled it again and tripped it again, over and over. The sharer captured and showed 58 fps while the viewer showed 10 to 48. Four frames are 67 ms at 60 fps, less than one Wi-Fi burst or one keyframe, so the rule now judges the backlog in time, waits for it to last, leaves the keyframe on its way out of it and gives the link half a second after the keyframe that ends a skip.

## 9. Windows and flow

Welcome: a single glass card on the dark background. Wordmark "Nítido" in Cormorant Garamond italic, a one-line subtitle, two buttons: Share and View. Below, in small caps, "by Ronald Rodríguez · RONAR AI".

Share: the system picker opens immediately. After choosing, the Share window shows the captured picture at native size, the telemetry strip at the bottom, a pairing panel at the top right with the sharer name and the 4-digit code (large, gold), the loopback toggle (⌘L) and, when loopback is on, the quality slider and the before/after divider. When a viewer connects, the panel shows the viewer's name and a small connected ring.

View: a list of discovered sharers with a 40 ms stagger as they appear; selecting one asks for the code; on success the View window shows the stream at the sharer's native size (scaled down only if the screen is smaller), the telemetry strip, and ink on top.

Shortcuts: ⌘Z undo last own stroke, ⌘⌫ clear all strokes, ⌘H toggle telemetry, ⌘L loopback (share side), ⌘, opens nothing (no preferences in the prototype), Esc stops sharing or disconnects after a confirmation.

Errors: shown inline in the window where they happen, in plain language, with the one action that fixes them (open System Settings for the permission, retry, pick another window).

## 10. Telemetry strip

A single row under the picture (when the picture is narrower than that row, the figures wrap onto further rows rather than widen the window past the picture), SF Mono figures, updated 4 times per second from 1-second rolling windows: capture fps (received fps on the viewer) · display fps · capture→display ms (exact in loopback, estimated across Macs) · RTT ms · bitrate Mbps · resolution and scale · codec. A 2-second sparkline of latency sits at the right end. Values that cross a threshold (latency over 100 ms, dropped frames) turn gold for one second, never red; the strip informs, it does not alarm. ⌘H hides it instantly, without animation.

## 11. Visual direction

Apple-grade restraint with the RONAR maison signature. Everything is quiet except the gold.

Colors (from maison.ronar.ai): background `#08090c`, surface `#0e1015`, hairline `#2b2e38`, muted `#3a3e4a`, text `#f2f3f5`, gold `#c9a86a`, gold highlight `#d8ba7e`, cream `#f3e3ba`, success `#62c37e`, soft red `#e08f8f` reserved for destructive confirmation only. Secondary text `#8a8f9c` (subtitles, small-caps captions, the strip's labels and units) keeps 4.5:1 or better on the background and the surface; muted (about 1.9:1) is for hairlines and inactive states only.

Type: SF Pro for all interface text (native feel on macOS), SF Mono for figures, Cormorant Garamond Italic only for the wordmark, Marcellus for small-caps labels (pairing code caption, section labels). Both fonts bundled under the SIL Open Font License.

Materials: on macOS 26 the welcome card, the pairing panel and the telemetry strip use `glassEffect`; on macOS 15 `.ultraThinMaterial` with a 1 px hairline. Corner radius 14 on cards, 10 on controls.

App icon: a dark rounded square with a thin gold italic N, in the family of the italic R mark; no wax seal, no crest (those belong to RONAR). Gold is applied as a subtle gradient from `#c9a86a` to `#d8ba7e`, never flat.

Motion, following the design engineering rules in use at RONAR:
- Entrances use `cubic-bezier(0.23, 1, 0.32, 1)` under 250 ms, from opacity 0 and scale 0.96, never from scale 0. Exits are faster than entrances.
- Press feedback on every button: scale 0.97 over 120 ms.
- The connect moment uses a spring (duration 0.5, bounce 0.2): a thin gold ring draws around the peer's name once, then settles. It plays once per connection, not on every pong.
- Discovered sharers stagger in at 40 ms intervals.
- Ink strokes fade 4 s after their last point, over 600 ms ease-out; undo removes a stroke with a 150 ms fade.
- Keyboard-triggered changes (⌘H, ⌘L, ⌘Z) are instant. Nothing animates on every frame except the picture itself and the sparkline.
- `accessibilityReduceMotion` removes the scale and the ring; opacity fades remain.

## 12. Failure design

| Situation | Behavior |
|---|---|
| Screen Recording not granted | Explain before the system prompt; after a denial, show the one-step path to System Settings and a Retry button. |
| Picker cancelled | The first pick: back to Welcome, no error. A change of content cancelled mid-share keeps the current content. |
| Display reconfigured mid-share, or the shared window resized | Once the new size holds for 150 ms, restart the stream at it, send a new `videoConfig` and a `hello` with the new size and scale, keyframe next. |
| Capture stopped by the system (Stop Sharing in the menu bar) | The Share window offers Retry; the viewer is told with `bye(2)` and says the sharer stopped sharing; the listener stops until Retry, or until a new pick from the system's picker starts the capture again and resumes the share. |
| Link drops | Both sides show "Reconnecting…": the viewer over the last frame (dimmed), the sharer next to the viewer's name in the pairing panel until the viewer pairs again (30 s at most). Backoff retries, keyframe on reconnect, strip shows the gap. |
| Quit or window closed mid-session | The session stops first, so the other side hears `bye`; the app quits once it is out (2 s at most). |
| Backlog grows | Skip non-key frames, lower bitrate, request keyframe; the strip shows the dropped count. |
| Encoder drops or fails a frame | A frame VideoToolbox drops (a realtime encoder under load) is a dropped frame: the strip counts it, the log says so at info at most once a second, and a keyframe it carried is asked for again; it never counts as a failure. Ten real encode failures in a row stop the codec and offer Retry (amended 2026-10-09: ten drops in a row under a keyframe storm had failed the share). |
| Decode error | Request keyframe; after three failures rebuild the decoder; after ten, show an error with Reconnect. |
| Wrong code | Reject with a shake of the code field (one 180 ms shake, respects reduce motion); three wrong codes regenerate the sharer's code (section 13 says how they are counted). |
| Protocol mismatch | `bye(1)` and a message naming both versions. |
| No hardware HEVC | Fall back to H.264 and label the codec in the strip. |

Every failure is visible in the UI and logged with `os.Logger` under subsystem `ai.ronar.nitido`; nothing is swallowed.

## 13. Security

TLS 1.2 with a pre-shared key derived with HKDF-SHA256 from the 4-digit code and the sharer's Bonjour name; the viewer must type the code shown on the sharer's screen. Ciphersuite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 5489: the PSK plus an ephemeral ECDH exchange). Network.framework negotiates it on macOS 26.5 (checked 2026-10-07 with a localhost listener and connection: right code connects, wrong code fails with "bad MAC"); `TLS_PSK_WITH_AES_128_GCM_SHA256` is the fallback only if an OS build refuses it, and the fallback is logged. A wrong code fails the handshake. Three wrong codes regenerate the code. The sharer counts attempts: handshakes that failed on the keys, a failure less than 1 s after the last one from the same address joining that address's attempt, up to four in a row, so one attempt that fails more than once is one wrong code, a code retyped after the shake (a second or more later) is another, and a guesser meets a new code by its ninth guess against each code; a rotation lets go of the handshakes still open on the old listener and counts afresh; a port scan, a refused or dropped connection and a protocol mismatch do not count. The listener binds to the local network only. Frames never touch disk.

Known limit, accepted for the LAN prototype (v0.1):
- The key is only as strong as the code: 10,000 values. The HKDF salt (`nitido-v1`) and info (the sharer name, which Bonjour broadcasts) are public, so HKDF adds no secrecy.
- Passive attacker (records the traffic only): with ECDHE_PSK the handshake keys also depend on the ephemeral ECDH secret, so a recorded handshake gives nothing to test codes against, and a recorded session stays unreadable even if the code leaks later (forward secrecy). With the plain PSK fallback this protection is gone: one recorded handshake is brute-forced offline in milliseconds and the whole screen and ink stream decrypted. That is why ECDHE_PSK is the default.
- Active attacker on the same LAN (spoofed Bonjour answer, ARP spoofing): it can pose as the sharer, take the viewer's Finished message, try all 10,000 codes against it in milliseconds, complete both handshakes and read or relay the stream in real time. The three-failure rotation does not help, because this attack needs no failed handshake. No ciphersuite fixes this with a 4-digit code.
- Therefore: trusted networks only (home, office), never public Wi-Fi. The README says so in plain words.
- Next step before any use beyond the demo (owner's choice): a PAKE over the code (SPAKE2 or SRP, where each active attempt tests one guess), or a 128-bit secret shared by QR code or link, or the section 17 certificate fallback (self-signed certificate pinned by fingerprint) with a longer code as the application-level check.

## 14. Testing

Unit (NitidoCore, NitidoCodec policy, NitidoLink framing):
- `Wire` round-trips every message type; the decoder survives arbitrary chunking and rejects oversized lengths.
- `BitrateController` scenarios: healthy ramps up 10% per 2 s; backlog triggers a 25% cut and a 2 s hold; bounds respected.
- `Ink` smoothing keeps endpoints fixed, width decreases with speed, undo pops the right stroke.
- `Telemetry` windows and percentiles against known sequences.
- `Pairing` derives the same key on both sides and a different key for a different code.

Integration:
- Two `Link` instances on localhost exchange `hello`, a `videoConfig`, 100 `videoFrame`s and strokes; kill one side, confirm reconnect and a `keyframeRequest`.
- Encoder and decoder loop a synthetic frame sequence; decoded size matches; a keyframe request produces a keyframe within one frame.

Manual checklist (documented in `docs/testing.md`): first-run permission flow, loopback at 1x and scaled, two instances on one Mac, two Macs on Wi-Fi, Wi-Fi off and on, display resolution change mid-share, reduce motion on.

## 15. Deliverables

- Public repository `github.com/ronald13ai/nitido` under the MIT license: source, this spec, README with screenshots, a 20-second GIF of the loop, how it works, measured numbers from this Mac, a Security section stating the section 13 limit in plain words, and "What's next" (WebRTC with STUN/TURN for the open internet, AV1 when hardware allows, a region-diff pass so static text costs no bits).
- `Nítido.app` signed with the Apple Development identity, zipped, with "right-click, Open" instructions; notarization added if a Developer ID certificate is obtained before Sunday.
- A 60 to 90 second video for Mark: pick a window, read the strip, flip loopback and the quality slider, connect the second Mac, draw from both sides, cut the Wi-Fi and watch it recover.

## 16. Schedule and fallback

- Wednesday 7: package skeleton, CaptureSession, VideoView at 1:1, telemetry strip. Demo: a window captured and measured.
- Thursday 8: VideoEncoder and VideoDecoder, loopback mode with slider and comparator, Ink with fade and undo. Demo: the codec loop with crisp text.
- Friday 9 and Saturday 10: Link with Bonjour, TLS PSK and pairing; video and strokes across two instances, then two Macs; reconnect and keyframe policy; bitrate controller wired. Demo: two Macs.
- Sunday 11: polish pass against section 11, app icon, bundle and signing, README, tests green, video recorded.
- Rule: if by Saturday night the link is not reliable on two Macs, the Sunday deliverable is the loopback build with the network layer described as next step in the README, and Mark is told exactly that.

## 17. Risks

- Screen Recording permission is granted per signed bundle: an unsigned or re-signed binary loses it. Mitigation: build the bundle and sign from day one.
- TLS PSK through Network.framework has sparse documentation. Mitigation: integration test on day three morning; if blocked by noon, fall back to TLS with a self-signed certificate pinned by fingerprint and keep the code as an application-level check.
- HEVC decode of another Mac's stream depends on matching parameter sets. Mitigation: `videoConfig` always precedes the first keyframe, and the decoder is rebuilt on every `videoConfig`.
- ScreenCaptureKit excluding Nítido's own windows needs the app's window list at stream start; windows created later must be added to the exclusion. Mitigation: a display is captured with a filter that excludes the Nítido application, which covers windows and sheets opened later; a window pick captures only that window.
- Display scale mismatch between Macs makes 1:1 impossible. Mitigation: scale down with Lanczos, show the scale in the strip, never scale up.
