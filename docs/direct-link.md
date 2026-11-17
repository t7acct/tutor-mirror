# Direct link (beta): measurements

TutorMirror 0.4.0 can take the picture straight from the iPad over AWDL, the
peer-to-peer Wi-Fi link AirDrop uses, instead of through the router. Turn it
on with View → Connect Directly to iPad (Beta). It's off by default.

## Why

Through the router, the video crosses the air twice (iPad → router → Mac).
On top of that, about once a second macOS takes the Mac's Wi-Fi off the
router's channel for AWDL (AirDrop, Handoff, Universal Clipboard). Frames
that arrive during that gap wait up to 100 ms. Over the direct link the
video only crosses the air once, and it's already on AWDL, so the gap
doesn't hold it up.

## Results

Same iPad Pro, MacBook Pro, room and router (5 GHz) on the same day
(17 November 2026), writing in Goodnotes. The numbers come from the lag
meter's log, one line every 2 seconds, counting only the 2-second stretches
when the iPad was sending.

| | Through the router (0.3.5, or the beta off) | Direct only (`peerToPeer` 2) | Router + direct (the menu option) |
|---|---|---|---|
| Time measured while writing | 72 s | 44 s | 84 s |
| Video the iPad sent | H.264 | H.265 | H.265 |
| Frames per second received / shown | 31 / 30 | 58 / 58 | 60 / 60 |
| Wi-Fi delay per frame, median / slowest 5% | 22 / 85 ms | 2 / 6.5 ms | 2 / 6.4 ms |
| Network part of the longest gap in each 2 s, median | 84 ms | 5 ms | 8 ms |
| 2-second stretches with a frame held up 40 ms or more | 92% | 0% | 0% |
| Mac side (decode + on screen), median | 22 ms | 17 ms | 18 ms |

"Wi-Fi delay per frame" is the lag meter's `delayed` number: how much longer
a frame took to arrive than the fastest recent one. "Network part of the
gap" is the longest gap between frames minus the part the iPad's own
timestamps explain (the iPad not sending because nothing changed).

In real lessons through the router (15 November, about 90 minutes of 2-second
samples) it was worse than the table: a median of about 40 ms and about
100 ms for the slowest 5%, with a frame held up about 85 ms in 80% of
the 2-second stretches.

In short, for a typical frame the measured delay went down by about 25 ms
(20 ms on Wi-Fi, 5 ms on the Mac), and the stall of about 85 ms that came
once a second went away. The iPad also sent twice as many frames, so writing
updates twice as often. Some of that may come from H.265 and not the link:
the iPad picks H.265 when it sends directly.

The base Wi-Fi travel time isn't in these numbers. Over the direct link the
iPad doesn't answer the clock-sync requests, so the lag meter can't work out
the full trip (its Wi-Fi round trip shows "-"). That makes the figures above
a lower bound on the gain, not the whole lag.

### Did it make the Mac's own Wi-Fi worse?

No sign of it. During each test the Mac pinged the router 10 times a second:

| | Pings over 30 ms | Slowest 5% |
|---|---|---|
| Through the router, with video | 2.1 a second | 79 ms |
| Direct only, with video | 1.3 a second | 71 ms |
| Router + direct, with video | 1.4 a second | 72 ms |

## What happens the first time

Over the direct link, iOS asks for a 4-digit code, like an Apple TV does.
TutorMirror shows it on the Mac's screen only, where students can't see it.
After that the iPad remembers the Mac and doesn't ask again.

## Not tested yet

- A Meet or Zoom call running at the same time. All the numbers above are
  without one.
- A whole lesson. The longest run was under 2 minutes.
- What happens if the direct link drops mid-lesson. With the menu option,
  TutorMirror also stays on the router, so the iPad should find it again
  there after reconnecting.
- Once, the iPad sat on "Connecting…" for about a minute and a half before
  anything reached the Mac. Then it connected in under a tenth of a second.
  The Mac's AWDL had been idle up to then. If it happens, wait, or pick the
  receiver again.

## How it works

- Bonjour advertises the receiver on AWDL as well
  (`kDNSServiceFlagsIncludeAWDL`), and every listener and socket accepts
  connections from AWDL.
- iOS requires pairing with a code over AWDL. TutorMirror implements AirPlay's
  legacy PIN pairing (SRP-6a, as in UxPlay and pyatv) and keeps its keys so
  the iPad trusts it next time.
- Over AWDL the iPad sends H.265. Without AirPlay feature bit 42
  (ScreenMultiCodec), it sends an empty codec packet and no picture can be
  decoded, so TutorMirror offers H.265 only while the direct link is on.
