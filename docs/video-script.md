# Nítido demo, 75 seconds, no voice-over, captions in the app only

Before recording: Nítido on two Macs on the same Wi-Fi, both screens recorded. Two copies on one Mac can also reach each other over loopback, which turning Wi-Fi off does not cut, so 1:02 needs the second Mac. On the first Mac, the TextEdit window holds a few pages, so it scrolls, and a Safari window shows a web page with photos for 0:28 (pick it with the screen-sharing menu in the menu bar, then pick TextEdit again). Nítido sends only frames that changed, and the strip reads near 0 over a still window: scroll the text wherever the script reads 60. The README's figures come from the strip at 0:08 (raw), 0:18 (codec loop at 20 Mbps) and 0:38 (two Macs).

0:00 Welcome card. Click Share. Pick the TextEdit window with 11 pt text.
0:08 The window appears 1:1. Scroll the text and zoom the recording on the strip: capture 60, display 60, capture to display in ms.
0:18 ⌘L while scrolling: codec HEVC appears, codec and bitrate show. Stop scrolling. Slide quality to 40 Mbps (it starts at 20), then drag the divider across a line of text: no difference.
0:28 Slide quality to 2 Mbps and scroll: the bitrate in the strip drops to the real rate, under 2 Mbps (the limit is honoured), and the text on the right stays sharp even while it moves. For the contrast, scroll a web page with images instead: the photos on the right lose detail while the left stays clean. Back to 30, then ⌘L to turn the loop off.
0:38 Second Mac: View, the name appears, type the code, connected. Scroll the text on the first Mac: the viewer's strip shows received 60, rtt and glass to glass (est.).
0:50 Draw on the viewer: cream stroke on the sharer. Draw on the sharer: cream on the viewer. Draw on the viewer again and press ⌘Z within four seconds, before the stroke fades: it leaves both.
1:02 Turn Wi-Fi off on the viewer. Reconnecting… attempt 1, 2. Turn it on: the picture comes back on its own.
1:12 Welcome card again, credit line. End.
