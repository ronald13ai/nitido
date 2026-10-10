# Nítido demo, 75 seconds, no voice-over, captions in the app only

Before recording: Nítido on two Macs on the same Wi-Fi, both screens recorded. The Wi-Fi drill at 1:02 needs the second Mac: two copies on one Mac may keep their link when the Wi-Fi goes off. On the first Mac, a TextEdit window holds a few pages of 12 pt text, so it scrolls, and a Safari window shows a web page with photos for 0:28 (pick it with the screen-sharing menu in the menu bar, then pick TextEdit again). No log window is needed: the strip shows every figure the video uses.

Nítido sends only frames that changed, so over a still window the capture and display figures fall to "·" and the bitrate to near zero: scroll the text wherever the script reads about 60. The README's figures come from the strip at 0:08 (raw), 0:18 (codec loop at 20 Mbps) and 0:38 (two Macs).

0:00 Welcome card. Click Share. Pick the TextEdit window (the text of item 8 in docs/testing.md).
0:08 The window appears 1:1. Scroll the text and zoom the recording on the strip: capture and display about 60, capture to display in ms.
0:18 While scrolling, turn on the Codec loop switch in the panel at the top left (⌘L does the same): the strip's codec reads HEVC, and the codec time and bitrate show. Stop scrolling. Slide quality to 40 Mbps (it starts at 20, and the label reads QUALITY · 40 MBPS), then drag the divider across a line of text: no difference.
0:28 Slide quality to 2 Mbps and scroll: the strip's bitrate drops to the real rate, under 2 Mbps (1.5 on 2026-10-09). Stop scrolling: the text on the right is as sharp as on the left. (Sharp text at 2 Mbps was seen on still text; check it while scrolling before recording, and show it holding while the text moves only if it does.) For the contrast, switch to the web page with photos and scroll it: the photos on the right lose detail while the left stays clean. Back to 30 Mbps, then turn the Codec loop switch off.
0:38 Second Mac: View (⌘⇧V), and the first Mac's name appears. Type a wrong code first: the field shakes once and says "Wrong code". Type the right one: connected, and on the first Mac a gold ring draws once around the dot next to the viewer's name. Scroll the text on the first Mac: the viewer's strip shows received about 60, rtt and glass to glass (est.).
0:50 Draw on the viewer: the stroke appears in cream on the sharer. Draw on the sharer: cream on the viewer. Draw on the viewer again and press ⌘Z within four seconds, before the stroke fades: it leaves both.
1:02 Turn the viewer's Wi-Fi off for about 10 s: "Reconnecting… attempt 1" over the dimmed picture, and Reconnecting… under the viewer's name on the sharer. Turn it on: the picture comes back on its own.
1:12 Welcome card again, credit line. End.
