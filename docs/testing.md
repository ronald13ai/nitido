# Manual checklist

Run before tagging a release. Each line is a pass/fail.

1. First run on a clean user: Share; while the picker is up, the Share screen says macOS may ask for Screen Recording after the pick and why; pick a window, macOS asks for Screen Recording; deny, the app explains and offers System Settings; grant, Retry works without relaunching.
2. Loopback at 1:1: TextEdit 12 pt text, Codec loop on at 40 Mbps, the right side matches the left to the pixel; at 2 Mbps small text smears; codec figure under 10 ms.
3. Window smaller than the content (big display shared to a small screen): downscaled, no horizontal blur bands, scale shown in the strip.
4. Two instances on one Mac: discover, pair, stream, ink both ways, ⌘Z both ways, ⌘⌫ both ways.
5. Two Macs on Wi-Fi: glass-to-glass under 100 ms at the sharer's native size; rtt shown; bitrate climbs to the ceiling within 10 s on a good network.
6. Wi-Fi off on the viewer for 10 s: Reconnecting overlay with growing attempts; Wi-Fi on: recovery with a keyframe, no restart.
7. Quit the sharer while connected: viewer shows "The sharer ended the session."; kill -9 the sharer: viewer reconnects when it comes back.
8. Three wrong codes: the sharer's code changes.
9. Display resolution change mid-share: the picture restarts at the new size on both sides.
10. Reduce Motion on: no scale, ring or shake; fades still happen; nothing feels broken.
11. ⌘H never animates. Esc asks before disconnecting, not before leaving Welcome.
