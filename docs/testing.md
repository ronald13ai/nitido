# Manual checklist

Run it on the build that will ship, before tagging a release. Each item is one action and the result it should give; it passes or fails.

The log lines quoted below are info lines. Read them with `log stream --info --predicate 'subsystem == "ai.ronar.nitido"'` (a plain `log stream` leaves them out; add `--debug` for the connection states).

## First run

1. On a user account that has never granted Nítido Screen Recording, click Share.\
   While the system picker is up, the Share window says macOS may ask for Screen Recording after the pick, and why.
2. Pick a window, and deny Screen Recording when macOS asks.\
   The Share window says "Nítido is not allowed to record the screen." with the fix, offers Open System Settings and Retry, and shows no system wording such as "TCC".
3. Turn on Screen Recording for Nítido in System Settings (choose Quit & Reopen if macOS offers it), then click Share and pick the window again.\
   The picture appears at 1:1 with the strip under it.
4. Open each menu on Welcome, then again over a live share.\
   Nítido appears once, as the app menu; File holds Share… (⌘N) and View… (⌘⇧V), Edit holds Undo Stroke and Clear Ink, View holds Toggle Telemetry and Codec Loop; every shortcut works from its menu, all of these but Share… and View… are dimmed on Welcome, and Codec Loop is dimmed away from a live share.
5. Press Esc on Welcome, in the picker, and on the list of Macs.\
   Welcome ignores it; the picker and the list go back to Welcome at once, without asking.
6. Press Esc over a live share, then over a connected viewer.\
   Each asks first ("Stop sharing?", "Disconnect?"), and the File menu's Esc item reads Stop Sharing or Disconnect to match.
7. With a share running, open View (⌘⇧V) and press Esc on the list of Macs.\
   It asks "Stop sharing?", because the share behind the list stops too.

## Picture

8. Share a TextEdit window with 12 pt text, turn on the Codec loop switch and set the slider to 40 Mbps.\
   Wherever you drag the divider, the text on its right looks the same as on its left at 1:1.
9. Set the slider to 2 Mbps, scroll the text, then stop.\
   The strip's bitrate stays at or under 2 Mbps while it scrolls, and once it stops the text on the right is as sharp as on the left (sharpness while it scrolls is still open: note what you see).
10. Still at 2 Mbps, scroll a web page with photos instead.\
    The photos on the right lose detail while the left stays clean.
11. Share a display larger than the screen that shows it: the whole display holding Nítido on one Mac, or a large display to a smaller viewer.\
    The picture is scaled down with no blur bands, and the strip adds the scale as a percentage.
12. Share the display that holds Nítido, press Esc, then cancel the question.\
    No Nítido window, sheet (the "Stop sharing?" one included) or mirror tunnel appears in the picture.
13. While sharing a display, change its resolution in System Settings, Displays.\
    The picture restarts at the new size, and the strip shows the new size and scale.
14. Share a TextEdit window and drag it larger, then smaller.\
    Each time, once the size holds, the picture restarts at the window's new size, 1:1 again, with the new size in the strip.
15. While sharing, open the screen-sharing menu in the menu bar, choose to change the shared content, then cancel.\
    The share goes on with the same content.
16. Stop a share and start another, once with Esc, Stop and Share on another window and once with Stop Sharing and a new pick in the menu bar's screen-sharing menu; after each, draw a stroke and let it fade.\
    The app keeps running (build cae00eb crashed here, in the ink canvas's tick).

## Two instances

17. Start a second copy with `open -n build/Nítido.app`, then click Share in the first and View in the second.\
    The second copy lists this Mac under the name the first one's pairing panel shows.
18. Pick it and type the code.\
    The picture appears with received fps and glass to glass (est.) in the strip, and the sharer's pairing panel shows the viewer's name with a gold ring drawn once.
19. Draw on each side.\
    Each side shows its own strokes in gold and the other side's in cream, and each stroke fades about four seconds after its last point.
20. Draw on each side and press ⌘Z within four seconds, then draw again and press ⌘⌫.\
    ⌘Z takes that side's newest stroke off both pictures, and ⌘⌫ clears both pictures.
21. With the viewer connected, pair a third copy with the same code.\
    The first viewer says "Another Mac is now viewing <Mac>.", the third copy shows the picture, and the sharer's panel shows its name.

## Two Macs

Both Macs on this build and the same Wi-Fi: the sharer a MacBook Pro with ProMotion, the viewer on a 60 Hz panel (a MacBook Air), both logs open.

22. Pair the two Macs.\
    The viewer's log says "The display refreshes at 60 Hz: allowing 2 in flight", and after that no "Frames kept waiting for a drawable", "Drawables come back in time again" or "nextDrawable() blocked the main thread" line.
23. Scroll a TextEdit window on the sharer.\
    The viewer's strip shows received and display close to 58 fps, dropped near 0, glass to glass (est.) under 100 ms and an RTT, and its log has no "the video decoder fell behind" line.
24. Scroll a 120-line TextEdit window on the sharer with the trackpad, without stopping, for 30 s.\
    The viewer's display fps stays close to the sharer's capture fps (build cae00eb swung between 10 and 48 for 58), and the sharer's log has at most an occasional "skipping frames until a keyframe" line, never a run of them each followed tens of milliseconds later by "the send backlog drained" (a drained line ending "the keyframe goes when the half-second limit is up" is the keyframe limit at work, not another skip).
25. During the same scroll, watch the sharer's log and strip.\
    The log shows at most one "Drawables are presented every 16.7 ms although the display says 120 Hz: allowing 2 in flight" line, then no "Drawables come back in time again" and no run of "Frames kept waiting for a drawable", and the strip shows dropped near 0 (build cae00eb swung between one and two in flight every 20 to 30 s).
26. During the same scroll, look for VideoToolbox's drops in the sharer's log.\
    Any "VideoToolbox dropped N frames" line is at info and at most one a second, and the Share window never says "Video encoding keeps failing."
27. Measure the same colour swatch with Digital Color Meter, set to sRGB, on the sharer's screen and in the viewer's picture.\
    The two readings agree within 2 code values per channel.
28. Type three wrong codes on the viewer, each once the field has shaken (changing a digit and pressing Return is enough).\
    Each says "Wrong code" at once, and the sharer's code changes after the third, not before.

## Failure drills

These need two Macs: two copies on one Mac may keep their link when the Wi-Fi goes off.

29. Turn the viewer's Wi-Fi off for 10 s, then on again.\
    While it is off the viewer shows "Reconnecting… attempt n" over the dimmed picture and the sharer's panel shows the viewer as Reconnecting…; once it is back, the picture recovers with a keyframe and no restart.
30. Draw on the viewer and turn its Wi-Fi off before letting go.\
    On the sharer the stroke stops growing and fades about four seconds after the link drops, instead of staying until ⌘⌫.
31. With a viewer connected, quit the sharer with ⌘Q; then relaunch it, share, pair again and close the sharer's window.\
    Each time the viewer says "The sharer ended the session."
32. With a viewer connected, kill the sharer with `kill -9`.\
    The viewer shows "Reconnecting… attempt n", with growing gaps between attempts.
33. Relaunch the sharer and share again.\
    Within a few seconds the viewer says "The code on <Mac> has changed. Enter the new code to connect again.", and the sharer's new code does not change by itself.
34. With a viewer connected, choose Stop Sharing in the menu bar's screen-sharing menu, then press Retry on the sharer.\
    The Share window says "Sharing was stopped from the menu bar." and hides the code and the Codec loop switch, the viewer says "<Mac> stopped sharing.", and after Retry the viewer pairs again with the same code.

## Motion

35. Turn on Reduce Motion (System Settings, Accessibility, Display), then pair a viewer, typing a wrong code first, and draw.\
    No scale, connect ring or shake appears; fades still happen, at full length, and nothing looks broken.
36. Press ⌘H on the Share and View screens.\
    The strip hides and shows at once, with no animation.

## Before publishing

On the build that will ship, during the two-Mac session; its commit goes in the Build column of the README's Measured table.

1. Read every figure in the README's Measured table from the strip again: the two-Mac rows (the 2026-10-09 figures predate that evening's fixes), the codec loop at 20 Mbps on the same 1346×878 window, and raw capture to display with the whole 3024×1964 display shared. Delete a row you cannot measure.
2. Capture `docs/screenshots/01-welcome.png`, `02-share-loopback.png`, `03-viewer.png` and `04-strip.png`, and record a 20-second GIF of the codec loop as `docs/screenshots/loop.gif`. Delete the README's link to any you skip, then delete `docs/screenshots/.gitkeep`.
3. Run `scripts/bundle.sh` and attach `build/Nitido-0.1-macOS15.zip` to a v0.1 release on GitHub.
4. Run `scripts/check-readme.sh`: it passes once no "(fill in)" is left, every image the README shows is tracked by git, and there is no em dash.
