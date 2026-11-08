# Architecture

What exists now. Decisions live in `docs/decisions/`.

```
iPad (NibPad)                                Mac (NibMac, menu bar)
PenCaptureView ─▶ NetworkSink ─▶ PenLinkSender  ══▶  PenLinkReceiver ─▶ PenInjectionController
(UIKit, black)                  TCP control + UDP     (one session)      DisplayMapper ─▶ TabletEventBuilder
                                40-byte PenSample                                         ─▶ TabletInjector (CGEvent)
```

## NibCore (`Packages/NibCore`)

Platform-agnostic unless noted; macOS-only files sit behind `#if os(macOS)`.

- `PenSample` + `PenSampleCodec` — the hot-path message: fixed 40-byte
  little-endian packet, strict decode, wrap-aware `isSequence` (decision 0002).
- `PencilNormalizer` — UIKit touch values → normalized, clamped, NaN-safe
  sample fields.
- `Transport/` (decision 0004)
  - `ControlMessage` + `ControlFramer` — length-prefixed JSON over TCP:
    hello / helloAck / geometry / ping / probe / gesture / frontApp.
  - `SessionCipher` — authenticated post-hello control and sample frames with
    per-direction keys, counters, and a per-session sample epoch.
  - `SampleSequencer` — drops not-newer UDP samples.
  - `PenLink` — `PenLinkSender` (iPad: Bonjour browse, hello, UDP send,
    triple-send of state transitions, 1 s ping, 3 s timeout, reconnect) and
    `PenLinkReceiver` (Mac: advertise `_nib._tcp`, accept hook, single
    session, UDP only from the accepted host). Session rules are in the
    pure `ReceiverSession` for tests.
- `Transport/USB/` (decision 0005) — `UsbmuxPacket` (usbmuxd plist protocol),
  `StreamFramer` (0x01 control / 0x02 sample frames), `UsbmuxClient` (Mac:
  discover attached iPads, connect to port 47811, retry), `UsbLinkListener`
  (iPad: loopback-only, 1 s ping, 3 s timeout). USB wins over Wi-Fi; a busy
  Wi-Fi sender retries every 2 s so unplugging falls back automatically.
- `Settings/` (decision 0006) — `PadSettings` (pressure curve, edge
  brightness, per-app `profiles`: buttons, strip, gesture options; owned by
  the iPad), `PadSettingsStore`, `PressureCurve` (applied on the iPad before
  sending), `KeyNames` (key picker table), `StripStepper`,
  `ShortcutButtonGestureMapper`, `ActiveHoldTracker`.
- `Gesture` (control message: scroll, zoom, undo, redo, `key(chord, tap|down|up)`)
  + `GesturePalmRejection` (iPad) + `GestureEventBuilder` (Mac: pixel scroll
  with phases, modifier+scroll zoom, keys; modifiers pressed/released with
  real `flagsChanged` events, held keys released at session end).
- `LinkStats` (rate, loss, gap/jitter p95, on demand) and
  `PlayoutScheduler` (adaptive jitter buffer, p95 + 2 ms, 2…40 ms).
- `DisplayMapper` — aspect-locked "force proportions" mapping: the whole
  display is reachable, the iPad's dead band clamps to the edge.
- `TabletMath` — altitude/azimuth → tilt x/y.
- macOS: `TabletEventBuilder` (proximity + tablet-point mouse events,
  capability mask 0x05C7, repairs missing down/up, drops predicted
  samples; decision 0003), `TabletInjector` (posts to the HID tap,
  `isTrusted`), `PenInjectionController` (map → build → post; releases
  the pen on session end; trust cached and refreshed by the host),
  `PenInjectionWorker` (serial `.userInteractive` queue owning the
  controller, scheduler and gesture posting; receive never touches main).
- Executables: `nib-inject-demo` (pressure-ramp S-curve, tests injection
  without an iPad), `nib-receive` (prints received samples, tests transport
  without NibMac).

## Apps

- `Apps/NibPad` — full-screen black `PenCaptureView`: Pencil-only touches
  with coalesced/predicted samples, hover via `UIHoverGestureRecognizer`,
  debounced proximity exit, eraser toggle via `UIPencilInteraction`,
  dimmed screen + idle timer off, debug HUD (switch in the panel; pressure,
  angles, rate, link state, fading trace). Four-finger tap opens the
  companion panel (pressure curve with force test strip, gesture options,
  HUD switch, profiles with `ProfileEditor`). `EdgeControlsView`: shortcut
  buttons and a scroll/zoom/brush strip from the active profile; finger
  touches routed by `PenCaptureView`, the Pencil always draws.
  `FingerGestureController`: two-finger scroll, pinch zoom,
  2/3-finger tap undo/redo. `NetworkSink` routes to USB when live, else
  Wi-Fi; predicted samples are never sent.
- `Apps/NibMac` — `MenuBarExtra` (`LSUIElement`): status ("<iPad> ·
  Connected via USB/Wi-Fi"), Accessibility item only while missing, display
  picker (persisted), Smoothing and Show Diagnostics toggles (link lines:
  Hz, loss, RTT, jitter, gap, delay, post), sends `frontApp` on accept and
  app activation, Allow/Deny prompt per iPad (remembered by device name —
  not authentication). Logs to `dev.yukai.nib` (`log stream --info`).

## Build and checks

- `project.yml` — XcodeGen; `Nib.xcodeproj` is generated, not committed.
- `scripts/verify.sh` — workflow check, `swift format lint`, `swift test`,
  unsigned builds of both apps.
