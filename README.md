<p align="center"><img src="docs/assets/logo.png" width="128" alt="Nib logo"></p>

# Nib

[![Verify](https://github.com/Yukaii/nib/actions/workflows/verify.yml/badge.svg)](https://github.com/Yukaii/nib/actions/workflows/verify.yml)

**Turn an iPad and Apple Pencil into a pressure-sensitive drawing tablet for your Mac.**

Nib works like a Wacom Intuos: the iPad screen stays dark, the Pencil maps
absolutely onto a Mac display, and Mac drawing apps — Krita, Photoshop,
Affinity — receive real tablet events with **pressure and tilt**. Fingers
handle the canvas: scroll, pinch to zoom, twist to rotate, tap to undo.

> **Developer preview.** Usable daily, but there are no downloadable builds
> yet: you build both apps from source with Xcode (below). Built and tested on
> an iPad mini (A17 Pro) with Apple Pencil Pro and an Apple Silicon Mac.
> Roadmap: [`PLAN.md`](PLAN.md).

## Features

- **Real tablet pressure and tilt** — injected as macOS tablet events, so apps
  treat Nib like a hardware tablet, not a mouse.
- **Screen-off drawing** — the iPad stays black (or faintly lit for edge
  buttons); you look at the Mac, not the iPad.
- **USB-C or Wi-Fi** — plug in for the lowest jitter; Nib switches to USB
  automatically and falls back to Wi-Fi when you unplug.
- **Trackpad-style gestures** — two-finger scroll, pinch to zoom and twist to
  rotate the canvas (sent as native macOS magnify/rotate gestures), two-finger
  tap to undo, three-finger tap to redo.
- **Shortcut buttons and a slide strip** — ExpressKeys-style buttons on one edge
  (tap or hold, e.g. hold Space to pan) and a strip on the other for scroll,
  zoom or brush size.
- **Per-app profiles** — the Mac reports the frontmost app and the iPad switches
  buttons and gestures to match. Presets for Krita, Photoshop and Affinity;
  edit everything on the iPad.
- **Pressure curve on the iPad** — soft/linear/firm presets, min/max
  thresholds, and a test strip that shows what the Mac receives.
- **Choose where you draw** — one display or all of them, the whole screen or a
  region, keep the iPad's proportions or stretch. An **edge margin** lets the
  Pencil reach the screen's edges (and an auto-hidden Dock) without touching
  the iPad's edge.
- **Paired and encrypted** — the iPad and Mac pair once by comparing a 6-digit
  code; after that every Pencil sample and command is encrypted, over Wi-Fi
  and USB.

## Requirements

- Mac with Apple Silicon, macOS 14 or later.
- iPad with Apple Pencil support (developed on iPad mini 6/7), iPadOS 18 or later.
- Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
  and an Apple ID signed in to Xcode (a free account works for personal installs).

## Build and install

There are no prebuilt downloads yet; build both apps from source.

```bash
git clone <this repo> nib && cd nib
xcodegen generate
open Nib.xcodeproj
```

1. In Xcode, select each target (`NibMac`, `NibPad`) → **Signing & Capabilities**,
   choose your team. If signing complains about the bundle identifier, change
   `bundleIdPrefix` and the two `PRODUCT_BUNDLE_IDENTIFIER`s in `project.yml`
   to your own reverse-DNS prefix and run `xcodegen generate` again.
2. Run **NibMac** on the Mac. It lives in the menu bar (no Dock icon).
3. Connect the iPad, select it as the run destination, and run **NibPad**.
   The first time, trust the developer profile on the iPad
   (Settings → General → VPN & Device Management).

## First run

Both apps walk you through setup on screen; this is the short version.

1. **Accessibility** — NibMac's setup window asks for Accessibility permission
   (it posts input events) and restarts itself once you grant it.
2. **Connect** — open Nib on the iPad and choose your Mac. Over Wi-Fi, both
   devices must be on the same network; allow Local Network access when asked.
   Over USB-C, plug in and accept "Trust This Computer".
3. **Pair** — tap **Pair** on the iPad and check that both screens show the
   same 6-digit code, then confirm on both. You only do this once; the keys
   are kept in the Keychain on each device.
4. **Draw** — the Mac's setup window has a test canvas: a light-to-heavy stroke
   should go from thin to thick.

## Settings

- **On the iPad** (four-finger tap): Connection, Pen (pressure curve and test
  strip), Profiles, Gestures, Display (edge brightness) and Advanced (debug
  HUD, reset).
- **On the Mac** (menu → **Settings…**): which display, the drawing area,
  proportions, edge margin, smoothing, launch at login and paired iPads.

## Using Nib

| On the iPad | On the Mac |
| --- | --- |
| Pencil | Tablet pen with pressure and tilt; double-tap / squeeze toggles eraser |
| Two-finger slide | Scroll / pan the canvas |
| Pinch / twist | Zoom / rotate the canvas |
| Two-finger tap / three-finger tap | Undo / redo |
| Edge buttons and strip | Keyboard shortcuts from the active profile |
| **Four-finger tap** | Opens the companion panel |

The **companion panel** holds the pressure curve, profiles (buttons, strip,
gesture options per app), edge-button brightness, and a debug HUD that shows
pressure, angles, sample rate and link state.

Each two-finger gesture decides once whether it is a scroll or a zoom/rotate,
so a twist does not turn into a scroll; a deliberate twist during a scroll still
switches to rotating.

## Troubleshooting

- **The cursor does not move** — Accessibility was probably granted while NibMac
  was running. Quit and reopen NibMac.
- **Stays on Wi-Fi with the cable plugged in** — bring Nib to the front on the
  iPad once (iPadOS closes its USB listener while suspended) and make sure the
  iPad trusts this Mac.
- **The Pencil stops for a few seconds every so often, in every app** — check
  Settings → Bluetooth. A Pencil that disconnects on a regular cycle (we saw
  every 30 s) is an iPadOS/Pencil pairing problem: forget the Pencil, restart the
  iPad, and pair again.
- **An app ignores pinch or rotate** — in that app's profile, set the zoom method
  to *Modifier + scroll*. Native gestures use undocumented macOS event fields
  (see [decision 0007](docs/decisions/0007-native-gesture-events.md)).
- Logs: `log stream --info --predicate 'subsystem == "dev.yukai.nib"'`.

## How it works

The iPad captures Pencil samples (position, force, altitude, azimuth) and sends
fixed 40-byte packets over UDP on Wi-Fi or a framed stream over USB (usbmuxd);
finger gestures, keys and settings-driven events travel on a reliable control
channel. NibMac maps samples onto the chosen display and posts CoreGraphics
tablet-proximity and tablet-point events. Details:
[`docs/architecture.md`](docs/architecture.md) and the decision records in
[`docs/decisions/`](docs/decisions/).

## Development

```bash
scripts/verify.sh                              # the gate: format, tests, both app builds
swift test --package-path Packages/NibCore     # unit tests only
swift run --package-path Packages/NibCore nib-inject-demo    # pressure stroke, no iPad needed
swift run --package-path Packages/NibCore nib-gesture-demo   # zoom/rotate the front app
```

Contributor and agent workflow: [`AGENTS.md`](AGENTS.md).

## Security note

The iPad and Mac pair by comparing a 6-digit code (commit-then-reveal, so a
device in the middle can't force matching codes). Every session after that is
authenticated and encrypted with ChaCha20-Poly1305, over Wi-Fi and USB. The
cable is not trusted on its own: USB pairs the same way. Details:
[decision 0011](docs/decisions/0011-pairing-and-encryption.md) and
[`docs/protocol.md`](docs/protocol.md). The handshake is ours and has been
reviewed, not audited; please report issues privately.

## License

[MIT](LICENSE)
