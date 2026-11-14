# TutorMirror

TutorMirror mirrors an iPad or iPhone to your Mac over AirPlay, with as little
lag as I could get out of it. I use it to teach online. I share the mirror
window on the call, and when I need to do something the student shouldn't
watch, I freeze it.

## Why I built it

I tutor online and do all my writing on an iPad in Goodnotes, mirrored to my
Mac so I can share it on Meet. The app I was using worked, but my handwriting
showed up noticeably behind my pen, which gets annoying fast when you're
working through a problem live.

The other thing was privacy. Every time I flipped to the answer key or set up
the next question, the student watched me do it. I wanted a button that just
holds the picture still.

So I forked [VirtualMirror](https://github.com/souriscloud/VirtualMirror),
rewrote the video side to be faster, and added freeze. A few things came
along with it: a blank "One moment…" screen, and a lag meter so I could see
where the delay comes from. The freeze and blank labels and the lag meter
only show on my screen. Screen sharing doesn't pick them up.

## Why it's faster

The AirPlay connection code is VirtualMirror's. I rewrote everything after
that, meaning how frames get decoded and drawn:

| | TutorMirror | VirtualMirror |
|---|---|---|
| Frame rate it asks the device for | 60 fps | 30 fps |
| Picture size it asks for | 2048×1536 (iPad shaped, so no black bars) | 1920×1080 |
| Colour conversion | none, a Metal shader draws the raw YUV | converts every frame to BGRA |
| Route to the screen | straight from the decoder to Metal, and only the newest frame gets drawn | decoder, then main thread, then SwiftUI, then a display layer |
| Network packets | read where they land, decrypted straight into the decoder's buffer | copied several times per frame |

The frame rate is the big one. Asking for 60 instead of 30 halves the time
between frames, and writing looks a lot smoother.

On my setup (iPad Pro, MacBook Pro, 120 Hz monitor, 5 GHz
Wi-Fi), decoding a frame takes about 3–4 ms and getting it on screen takes
about 16 ms. The Wi-Fi round trip is around 11 ms. Your Wi-Fi will matter more
than anything else.

## What you need

- A Mac on macOS 14 (Sonoma) or newer. Apple Silicon and Intel both work.
- An iPad or iPhone on the same Wi-Fi.
- Optional: turn off the Mac's built-in receiver (System Settings → General →
  AirDrop & Handoff → AirPlay Receiver) so you don't pick the wrong one from the list.

## Install

### Download it

1. Grab `TutorMirror.zip` from the [latest release](../../releases/latest),
   unzip it and drag TutorMirror.app into Applications.
2. I can't be asked paying £79 a year to Apple, so run this command in
   Terminal instead:

   ```bash
   xattr -dr com.apple.quarantine /Applications/TutorMirror.app
   ```

   (Otherwise macOS will block it the first time you open it.)

   Or go to System Settings → Privacy & Security, scroll down and click
   Open Anyway.

3. When it asks to find devices on your local network, say Allow. If you
   don't, your iPad won't be able to see it.

### Or build it

You'll need Xcode or its command line tools.

```bash
git clone https://github.com/t7acct/tutor-mirror.git
cd tutor-mirror
./build.sh --run
```

`./build.sh --release` makes a zip that runs on both Apple Silicon and Intel.

## Using it

1. Open TutorMirror.
2. On the iPad or iPhone: Control Center → Screen Mirroring → TutorMirror.
3. On your call, share the TutorMirror window, not your whole screen.

Then click the TutorMirror window and use these keys:

| Key | Your student sees | You see |
|---|---|---|
| F | the picture stops (F again goes live) | a blue FROZEN label |
| B | a "One moment…" screen (B again to undo) | a purple BLANK label |
| ⌘L | nothing | the lag meter |
| ⌃⌘F | the mirror, full screen | |

The keys only work while the TutorMirror window is in front, so you can still
type F and B in other apps. Freeze and Blank are also in the View menu and in
the menu bar icon.

Once you've frozen it, you can do whatever you like on the iPad. Flip pages,
rotate it, lock it, disconnect it. The student keeps seeing the still picture.
The app keeps decoding in the background while frozen, so going live again is
instant.

If you share your whole screen instead of the window, the student can see your
menu bar, and the menu bar icon says FROZEN when it's frozen. Share the window.

## Settings

Rename the receiver (the name in your device's Screen Mirroring list) under
View → Rename Receiver…. iPad audio is off by default. Turn it on with View →
Play iPad Audio.

There are a few more settings in `defaults`. Reconnect your device after
changing them.

```bash
defaults write local.tutormirror maxFPS -int 120         # ask for 120 fps (most devices still send 60)
defaults write local.tutormirror streamWidth -int 2732   # ask for a bigger picture
defaults write local.tutormirror streamHeight -int 2048
defaults delete local.tutormirror                        # back to defaults
```

To look at the lag numbers after a session:

```bash
log show --last 10m --predicate 'subsystem == "local.tutormirror" AND category == "Lag"'
```

## What works and what doesn't

I've only tested it with my iPad Pro running Goodnotes. Other iPads and
iPhones speak the same protocol, so they should be fine, and the window
reshapes itself for portrait, landscape and phones. If something breaks on
your device, open an issue.

It handles one device at a time. If a second one connects, it takes over.

It only does screen mirroring. Casting a YouTube video, audio-only AirPlay
from Music and 4K/H.265 streams won't work.

If your device can't find TutorMirror, check they're on the same network,
check TutorMirror is allowed under System Settings → Privacy & Security →
Local Network, and try View → Restart Receiver.

## What I want to add next

- Cropping out the iPad status bar and the Goodnotes toolbar, so students only see the page
- Drawing boxes and arrows on the mirror from the Mac
- Zooming into part of the page, and saving the board at the end of a lesson

## Credits and licence

This is a modified version of
[VirtualMirror](https://github.com/souriscloud/VirtualMirror) by Souris.CLOUD
(the exact commit is in `UPSTREAM.txt`), which builds on
[UxPlay](https://github.com/FDH2/UxPlay), [RPiPlay](https://github.com/FD-/RPiPlay)
and [shairplay](https://github.com/juhovh/shairplay). See
`ACKNOWLEDGMENTS-VirtualMirror.md`. I rewrote the video code in `Sources/Video`
and wrote the app and tutoring features in `Sources/App`. The protocol code
is theirs, with small changes.

GPL-3.0, same as the projects it's built on (see `LICENSE`). Not affiliated
with Apple. AirPlay, iPad and iPhone are Apple trademarks.
