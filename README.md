# TutorMirror

A fast AirPlay screen-mirroring receiver for the Mac, built for teaching online.
Mirror your iPad or iPhone to your Mac over Wi-Fi, share the mirror window in
Google Meet, Zoom or Teams, and freeze or blank what your student sees whenever
you need a moment.

## Why I built it

I tutor online. I write on an iPad in Goodnotes and mirror it to my Mac so I can
share it on a call. The mirroring app I was using worked, but it had enough lag
that my handwriting trailed behind my pen. It also had no way to stop the
student seeing everything I did on the iPad, like flipping to the answer key or
setting up the next question.

So I forked it and rebuilt the video path for speed. Then I added the things I
actually wanted while teaching:

- **Freeze**: the student sees a still picture while I carry on working on the iPad.
- **Blank**: the student sees "One moment…" while I set something up.
- **A lag meter** so I can see where the delay comes from.
- **Tags and meters only I can see**: they're left out of screen sharing.

## What makes it faster

TutorMirror is a fork of [VirtualMirror](https://github.com/souriscloud/VirtualMirror).
The AirPlay connection code is theirs. Everything after the network (the
decoding and drawing) was rewritten for low delay:

| | TutorMirror | VirtualMirror |
|---|---|---|
| Frame rate asked from the device | **60 fps** | 30 fps |
| Picture size asked for | **2048×1536** (4:3, sharp on iPad, no black bars) | 1920×1080 |
| Colour conversion | none: native YUV drawn by a Metal shader | BGRA conversion every frame |
| Path to the screen | decode thread → Metal, newest frame always wins | decode → main thread → SwiftUI → display layer |
| Network packets | parsed in place, decrypted straight into the decoder | several copies per frame |

On my setup (iPad Pro, MacBook Pro, 120 Hz monitor, 5 GHz
Wi-Fi), each frame takes about 3–4 ms to decode and about 16 ms to reach the
screen. The Wi-Fi round trip is about 11 ms. Your numbers depend mostly on your
Wi-Fi.

## Requirements

- A Mac running **macOS 14 Sonoma or later** (Apple Silicon or Intel)
- An **iPad or iPhone** on the same Wi-Fi network
- Turning off macOS's own receiver helps avoid confusion: System Settings →
  General → AirDrop & Handoff → **AirPlay Receiver** off

## Install

### Option 1: download (easiest)

1. Download `TutorMirror.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **TutorMirror.app** to your Applications folder.
3. The app isn't from the App Store, so the first time you open it, macOS will
   block it. Go to System Settings → Privacy & Security, scroll down and click
   **Open Anyway**. Or run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/TutorMirror.app
   ```

4. When macOS asks whether TutorMirror can find devices on your local network,
   click **Allow**. Without it, your iPad can't see the Mac.

### Option 2: build it yourself

You need Xcode (or its command-line tools).

```bash
git clone https://github.com/t7acct/tutor-mirror.git
cd tutor-mirror
./build.sh --run
```

`./build.sh --release` makes a universal (Apple Silicon + Intel) zip in `build/`.

## How to use it

1. Open TutorMirror on the Mac.
2. On the iPad or iPhone, open Control Center → **Screen Mirroring** → **TutorMirror**.
3. In your video call, share **the TutorMirror window** (not your whole screen).

Click the TutorMirror window, then use:

| Key | Your student sees | You see |
|---|---|---|
| **F** | a still picture (press F again to go live) | a blue FROZEN tag |
| **B** | a "One moment…" screen (press B again to undo) | a purple BLANK tag |
| **⌘L** | nothing | the lag meter |
| **⌃⌘F** | the mirror full screen | |

These are single keys, and they only work while the TutorMirror window is in
front, so typing in other apps is unaffected. Freeze and Blank are also in the
View menu and the menu bar icon.

While frozen, you can do anything on the iPad: flip pages, rotate it, lock it,
even disconnect. The student keeps seeing the frozen picture. Going live again
is instant, because the app keeps decoding in the background.

**Tip:** if you share your *whole screen* instead of the window, your student
can see your menu bar, including the menu bar icon's FROZEN label. Share the
window.

## Settings

- **Rename the receiver**: View → Rename Receiver… (the name your device shows
  under Screen Mirroring)
- **iPad audio**: off by default, turn it on under View → Play iPad Audio

Advanced settings live in `defaults` (reconnect your device after changing them):

```bash
defaults write local.tutormirror maxFPS -int 120         # ask for 120 fps (most devices still send 60)
defaults write local.tutormirror streamWidth -int 2732   # ask for a bigger picture
defaults write local.tutormirror streamHeight -int 2048
defaults delete local.tutormirror                        # back to defaults
```

To see the lag numbers from a session afterwards:

```bash
log show --last 10m --predicate 'subsystem == "local.tutormirror" AND category == "Lag"'
```

## What works

- **iPad and iPhone screen mirroring.** I've tested it with an iPad Pro running
  Goodnotes. Other iPads and iPhones use the same protocol and should work. The
  window reshapes itself for portrait, landscape and phone screens.
- **One device at a time.** A new device replaces the current one.
- **Not supported:** AirPlay video "casting" (sending a YouTube video to the TV),
  audio-only AirPlay from Music, and 4K/H.265 streams. TutorMirror is for
  screen mirroring.

If your device can't see TutorMirror: check both devices are on the same
network, check TutorMirror is allowed under System Settings → Privacy &
Security → Local Network, and try View → Restart Receiver.

## Roadmap

- Crop out the iPad status bar and app toolbars, so students see just the page
- Draw boxes, arrows and highlights on the mirror from the Mac
- Zoom and spotlight, and save snapshots of the board after a lesson

## Credits and licence

TutorMirror is a modified version of
[VirtualMirror](https://github.com/souriscloud/VirtualMirror) by Souris.CLOUD.
The commit it's based on is in `UPSTREAM.txt`. VirtualMirror builds on
[UxPlay](https://github.com/FDH2/UxPlay), [RPiPlay](https://github.com/FD-/RPiPlay)
and [shairplay](https://github.com/juhovh/shairplay); see
`ACKNOWLEDGMENTS-VirtualMirror.md`. Changes from VirtualMirror: the video
receive, decode and display code (`Sources/Video`) and the app and tutoring
features (`Sources/App`) are rewritten or new. The protocol code is adapted with
small changes.

Licensed under the GNU General Public License v3.0 (see `LICENSE`), like the
projects it builds on. This project isn't affiliated with Apple. AirPlay, iPad
and iPhone are trademarks of Apple Inc.
