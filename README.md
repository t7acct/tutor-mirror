# TutorMirror

A low-latency AirPlay receiver for macOS, built for online tutoring: mirror an
iPad (Goodnotes) to the Mac over Wi-Fi, share the mirror window in Google Meet,
Zoom or Teams, and freeze or blank what the student sees while you prepare.

## Why it's faster than VirtualMirror

| | TutorMirror | VirtualMirror |
|---|---|---|
| Frame rate asked from the iPad | 60 fps | 30 fps |
| Picture size | 2048×1536 (exact 4:3, no black bars) | 1920×1080 |
| Colour conversion | none: native YUV drawn by a Metal shader | BGRA conversion every frame |
| Path to the screen | decode thread → Metal, newest frame wins | decode → main thread → SwiftUI → display layer |
| Packet handling | parsed in place, decrypted straight into the decoder buffer | several copies per frame |

Measured with an iPad Pro on a 120 Hz monitor: about 3.5 ms decode
and about 16 ms to get onto the screen. The Wi-Fi round trip was about 11 ms.

## Using it

1. Build and launch: `./build.sh --run`
2. On the iPad, go to Control Center → Screen Mirroring → **TutorMirror**.
3. In Meet, Zoom or Teams, share the **TutorMirror window**.

With the mirror window in front:

| Key | Student sees | You see |
|---|---|---|
| **F** | a still picture (press F again to go live) | blue FROZEN tag |
| **B** | "One moment…" (press B again to undo) | purple BLANK tag |
| **⌘L** | nothing | lag meter (only you can see it) |

The FROZEN/BLANK tags and the lag meter are left out of screen capture, so the
student doesn't see them, whether you share the window or the whole screen.
While frozen, the iPad can flip pages, rotate, lock or even disconnect.

## Settings

```bash
defaults write local.tutormirror maxFPS -int 120          # try 120 fps
defaults write local.tutormirror streamWidth -int 2732    # full iPad resolution
defaults write local.tutormirror streamHeight -int 2048
defaults write local.tutormirror receiverName "Maths Mirror"
```

Reconnect the iPad after changing them.

Lag logs from a session:

```bash
log show --last 10m --predicate 'subsystem == "local.tutormirror" AND category == "Lag"'
```

Developer self-test (fake 60 fps stream, no iPad needed):

```bash
TUTORMIRROR_SELFTEST=1 build/TutorMirror.app/Contents/MacOS/TutorMirror
```

## Credits and licence

The AirPlay protocol, pairing and FairPlay code come from
[VirtualMirror](https://github.com/souriscloud/VirtualMirror) (see
`UPSTREAM.txt`), which builds on UxPlay, RPiPlay and shairplay. The video path
and the tutoring features are new. Licensed under GPL-3.0 (see `LICENSE`).
