# Manual checklist

Run it on the build that will ship, before tagging a release. Each item is one action and the result it should give; it passes or fails.

The log lines quoted below are info or error lines. Read them with `log stream --info --predicate 'subsystem == "ai.ronar.nitido"'` (a plain `log stream` leaves them out; add `--debug` for the connection states).

## First run

1. On a user account that has never granted Nítido Screen Recording, click Share.\
   While the system picker is up, the Share window says macOS may ask for Screen Recording after the pick, and why.
2. Pick a window, and deny Screen Recording when macOS asks.\
   The Share window says "Nítido is not allowed to record the screen." with the fix, offers Open System Settings and Retry, and shows no system wording such as "TCC".
3. Turn on Screen Recording for Nítido in System Settings, choose Later if macOS offers Quit & Reopen, then press Quit and Reopen on Nítido's card, click Share in the copy that opens and pick the window again.\
   The card said to quit and reopen (not Retry) and that a switch already on belongs to another copy; Quit and Reopen opened Nítido again on Welcome, and the picture appears at 1:1 with the strip under it.
4. Open each menu on Welcome, then again over a live share.\
   Nítido appears once, as the app menu; File holds Share… (⌘N) and View… (⌘⇧V), Edit holds Undo Stroke and Clear Ink, View holds Toggle Telemetry and Codec Loop; every shortcut works from its menu, all of these but Share… and View… are dimmed on Welcome, and Codec Loop is dimmed away from a live share.
5. Press Esc on Welcome, in the picker, on the code screen of a Mac in the list, and on the list of Macs.\
   Welcome ignores it; the picker and the list go back to Welcome at once, without asking; the code screen goes back to the list, as its Back button does.
6. Press Esc over a live share, then over a connected viewer.\
   Each asks first ("Stop sharing?", "Disconnect?"), and the File menu's Esc item reads Stop Sharing or Disconnect to match.
7. With a share running, open View (⌘⇧V) and press Esc on the list of Macs.\
   It asks "Stop sharing?", because the share behind the list stops too.

## Picture

8. Share a TextEdit window with 12 pt text, turn on the Codec loop switch and set the slider to 40 Mbps.\
   Wherever you drag the divider, the text on its right looks the same as on its left at 1:1.
9. Set the slider to 2 Mbps, scroll the text, then stop.\
   While it scrolls, the strip's dropped figure stays near 0 and its bitrate close to 2 Mbps, higher for a second after each keyframe (one every 2 s) but never over 8 (the encoder's hard limit is twice the slider over 2 s); once it stops, the text on the right is as sharp as on the left (sharpness while it scrolls is still open: note what you see).
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
    The viewer's display fps stays close to the sharer's capture fps (build cae00eb swung between 10 and 48 for 58), and the sharer's log has at most an occasional "skipping frames until a keyframe" line, never a run of them each followed tens of milliseconds later by "the send backlog drained" (a drained line that says the keyframe goes when the half-second limit is up is the keyframe limit at work, not another skip).
25. During the same scroll, watch the sharer's log and strip.\
    The log shows at most one "Drawables are presented every 16.7 ms although the display says 120 Hz: allowing 2 in flight" line, then no "Drawables come back in time again" and no run of "Frames kept waiting for a drawable", and the strip shows dropped near 0 (build cae00eb swung between one and two in flight every 20 to 30 s).
26. During the same scroll, look for VideoToolbox's drops in the sharer's log.\
    Any "VideoToolbox dropped N frames" line is at info and at most one a second, and the Share window never says "Video encoding keeps failing."
27. Measure the same colour swatch with Digital Color Meter, set to sRGB, on the sharer's screen and in the viewer's picture.\
    The two readings agree within 2 code values per channel.
28. Type three wrong codes on the viewer, waiting a second after each shake before pressing Return (changing one digit is enough).\
    Each says "Wrong code" at once, and the sharer's code changes after the third, not before.

## Failure drills

Items 29 and 30 need two Macs: two copies on one Mac may keep their link when the Wi-Fi goes off. Items 31 to 34 also work with two copies on one Mac.

29. Turn the viewer's Wi-Fi off for 10 s, then on again.\
    While it is off the viewer shows "Reconnecting…" over the dimmed picture and the sharer's panel shows the viewer as Reconnecting…, its gold ring gone; once it is back, the picture recovers with a keyframe, the ring draws again, and nothing restarts.
30. Draw on the viewer and turn its Wi-Fi off before letting go.\
    On the sharer the stroke stops growing and fades about seven seconds after the Wi-Fi goes off (three to notice the drop, four before the fade), instead of staying until ⌘⌫.
31. With a viewer connected, quit the sharer with ⌘Q and choose Stop; then relaunch it, share, pair again, click the sharer's close button and choose Stop.\
    Each time the sharer asks "Stop sharing?" first, and the viewer says "The sharer ended the session."
32. With a viewer connected, kill the sharer with `kill -9`, and leave it killed.\
    The viewer shows "Reconnecting…", its log ("link failed (...); retry n in ...s") shows growing gaps between attempts, and about 30 s after the kill it says "<Mac> is no longer sharing." with Try again and Back.
33. Pair again, kill the sharer with `kill -9`, then within 20 s relaunch it and share again.\
    Within a few seconds of the share the viewer says "The code on <Mac> has changed. Enter the new code to connect again.", and the sharer's new code does not change by itself.
34. With a viewer connected, choose Stop Sharing in the menu bar's screen-sharing menu, then press Retry on the sharer.\
    The Share window says "Sharing was stopped from the menu bar." over the dimmed last picture and hides the code, the Codec loop switch and the strip, the viewer says "<Mac> stopped sharing." over its own last frame, and after Retry the viewer pairs again with the same code.

## Motion

35. Turn on Reduce Motion (System Settings, Accessibility, Display), then pair a viewer, typing a wrong code first, and draw.\
    No scale, connect ring, turning arc or shake appears; fades still happen, at full length, and nothing looks broken.
36. Press ⌘H on the Share and View screens.\
    The strip hides and shows at once, with no animation.

## Long sessions and edges

Added on 2026-10-11 for what the journey review found; on the two Macs unless an item says otherwise.

37. On battery on both Macs, with `caffeinate` not running (`pgrep caffeinate` prints nothing), pair them and leave both untouched for 10 minutes, longer than the display-off time in System Settings, Battery. Run `pmset -g assertions | grep -i nitido` on each Mac during the session and again after Esc ends it.\
    Both displays stay on and the session stays connected; during it each Mac lists Nítido preventing idle display sleep and idle system sleep ("Viewing <Mac>" on the viewer, "Sharing the screen" on the sharer), and after it neither does.

38. With a viewer connected, press ⌘W on the viewer, then click its close button, then press ⌘Q, choosing Cancel each time; then press ⌘W and choose Disconnect.\
    Each time the viewer asks "Disconnect?" and Cancel keeps the picture live and the sharer's panel unchanged; after Disconnect the viewer quits and the sharer shows no viewer.
39. Connected as a viewer, press ⌘N, cancel the system picker; then ⌘N again, pick a window, choose Stop Sharing in the menu bar's screen-sharing menu, press Retry and cancel that picker. Then press ⌘N and, with the picker up, press Esc in the Nítido window; then ⌘N, pick a window, choose Stop Sharing in the menu bar and press Esc on the failure card.\
    Each cancel and each Esc goes back to the View screen with the picture still live and no question asked (on the picker and the failure card the File menu's Esc item reads Cancel Sharing), and the sharer's panel keeps this Mac as its viewer.
40. On a 1x display (or with the display at a scaled mode that gives 1 px per point), share a TextEdit window and drag it to an odd width and height (the strip's size figure ends in odd numbers, such as 1347×879), turn on the Codec loop at 60 Mbps and drag the divider across, then pair a viewer.\
    The text right of the divider is as sharp as left of it across the whole picture, middle included, with no step at the divider; the viewer's picture is the same size as in the sharer's strip, with no dark line along its left or bottom edge.
41. With viewer A connected, close A's lid (or turn its Wi-Fi off) for a minute; meanwhile pair viewer B, a third Mac or a second copy on another Mac, with the same code; then open A again.\
    A says "Another Mac is now viewing <Mac>." over its last frame and B keeps the picture; pressing Try again on A and typing the code makes A the viewer, and B then says it.
42. With both Macs on the same Wi-Fi and nothing else using AirDrop, Handoff or Sidecar, run `ping -i 0.1 -c 300 <router>` on the viewer, then on the sharer, three times each: with Nítido closed, while paired, and while the viewer shows the list of Macs; note `ifconfig awdl0 | grep status` each time, and the strip's RTT and the latency sparkline while paired.\
    While paired the viewer's ping has no more spikes than with Nítido closed (its round-trip maximum and the spread of the 300 replies about the same), while the list shows them as before; note what the sharer's ping and `awdl0` status do while paired, since the sharer still advertises over AWDL.
43. Share a small window (Calculator, or a palette 200 by 100 px), turn the Codec loop on, then pair a viewer and quit the sharer.\
    The Share window is at least 480 by 260 pt with the picture centred on the background, the loop panel and the pairing panel side by side with all four digits readable; the viewer's window is as large, and its "The session ended" card shows whole, buttons included.
44. With VoiceOver on (⌘F5) on the viewer, type a wrong code, then the right one, then turn the sharer's Wi-Fi off for 10 s; then move the VoiceOver cursor to the picture.\
    VoiceOver says "Wrong code", "Connected to <Mac>" and "Reconnecting to <Mac>", and names the picture "Screen shared by <Mac>", an image.
45. Run seven or more copies sharing (`open -n build/Nítido.app` on two Macs), and open View on another.\
    The list scrolls inside the window, and every Mac can be reached and picked.
46. With a viewer on a Mac with a Retina display and an external 1x display, draw a stroke over a word and, within four seconds, drag the viewer window to the other display; then, with the pointer over the picture, press ⌘Tab to another app.\
    The stroke stays on the word at the new size while it fades, and the sharer's gold dot for the viewer disappears at the ⌘Tab.
47. On the macOS 15 Mac and the macOS 26 Mac, look at Nítido.app in Finder's list view, in Spotlight's results and in the ⌘Tab switcher.\
    Note how the N reads at those small sizes on each system (the icon there is Icon Composer's, flattened; spec 11 says why the tuned small sizes do not reach it).

## Before publishing

Steps 1 and 2 on the build that will ship, during the two-Mac session; its commit goes in the Build column of the README's Measured table.

1. Read every figure in the README's Measured table from the strip again: the two-Mac rows (the 2026-10-09 figures predate the fixes made after the evening run), the codec loop at 20 Mbps on the same 1346×878 window, and raw capture to display with the whole 3024×1964 display shared. Delete a row you cannot measure.
2. Capture `docs/screenshots/01-welcome.png`, `02-share-loopback.png`, `03-viewer.png` and `04-strip.png`, and record a 20-second GIF of the codec loop as `docs/screenshots/loop.gif`. Delete the README's link to any you skip, then delete `docs/screenshots/.gitkeep`.
3. Run `scripts/check-readme.sh`: it passes once no "(fill in)" is left, every image the README shows is tracked by git, and there is no em dash.
4. Merge build/v0.1 into main, create github.com/ronald13ai/nitido, push main and make it public; check that the README's clone URL and releases link open.
5. Run `scripts/bundle.sh` and attach `build/Nitido-0.1-macOS15.zip` to a v0.1 release on GitHub.
