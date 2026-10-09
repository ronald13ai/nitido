# Manual checklist

Run before tagging a release. Each line is a pass/fail.

1. First run on a clean user: Share; while the picker is up, the Share screen says macOS may ask for Screen Recording after the pick and why; pick a window, macOS asks for Screen Recording; deny, the app explains and offers System Settings; grant, Retry works without relaunching.
2. Loopback at 1:1: TextEdit 12 pt text, Codec loop on at 40 Mbps, the right side matches the left to the pixel; at 2 Mbps small text smears; codec figure under 10 ms.
3. Window smaller than the content (big display shared to a small screen): downscaled, no horizontal blur bands, scale shown in the strip.
4. Two instances on one Mac: discover, pair, stream, ink both ways, ⌘Z both ways, ⌘⌫ both ways.
5. Two Macs on Wi-Fi: glass-to-glass under 100 ms at the sharer's native size; rtt shown; bitrate climbs to the ceiling within 10 s on a good network.
6. Wi-Fi off on the viewer for 10 s: Reconnecting overlay with growing attempts, and the sharer's pairing panel shows the viewer as Reconnecting…; Wi-Fi on: recovery with a keyframe, no restart.
7. Quit the sharer with ⌘Q, and again by closing its window, while connected: viewer shows "The sharer ended the session." each time. kill -9 the sharer: viewer shows "Reconnecting… attempt n" with growing gaps; relaunch the sharer: it has a new code, so the viewer says "The code on <Mac> has changed. Enter the new code to connect again."
8. Three wrong codes, each typed once the field has shaken: every one says Wrong code at once on the viewer, between two Macs too, and the sharer's code changes after the third, not before (failed handshakes from one address within 3 s count as one wrong code; a port scan never counts).
9. Display resolution change mid-share (share the display), then share a TextEdit window and drag it larger and smaller: each time the picture restarts at the new size on both sides, 1:1 again, with the new size and scale in both strips.
10. Reduce Motion on: no scale, ring or shake; fades still happen; nothing feels broken.
11. ⌘H never animates. Esc asks before disconnecting, not before leaving Welcome; with a share running behind the View screen it asks "Stop sharing and disconnect?".
12. Share the display that holds Nítido: neither the Share window nor the viewer shows a Nítido window, sheet (Esc's Stop sharing? included) or mirror tunnel.
13. While sharing, open the system's screen-sharing menu in the menu bar, choose to change the shared content, then cancel: the share goes on with the same content and the viewer stays connected.
14. With a viewer connected, click Stop Sharing in the menu bar's screen-sharing menu: the Share window offers Retry, the viewer says "<Mac> stopped sharing.", and after Retry the viewer can pair again with the same code.
15. The menu bar shows Nítido once (the app menu); Share… and View… are in File, Undo Stroke and Clear Ink in Edit, Toggle Telemetry and Codec Loop in View, and every shortcut works from its menu.
