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
    hello / helloAck / geometry / ping.
  - `SampleSequencer` — drops not-newer UDP samples.
  - `PenLink` — `PenLinkSender` (iPad: Bonjour browse, hello, UDP send,
    triple-send of state transitions, 1 s ping, 3 s timeout, reconnect) and
    `PenLinkReceiver` (Mac: advertise `_nib._tcp`, accept hook, single
    session, UDP only from the accepted host). Session rules are in the
    pure `ReceiverSession` for tests.
- `DisplayMapper` — aspect-locked "force proportions" mapping: the whole
  display is reachable, the iPad's dead band clamps to the edge.
- `TabletMath` — altitude/azimuth → tilt x/y.
- macOS: `TabletEventBuilder` (proximity + tablet-point mouse events,
  capability mask 0x05C7, repairs missing down/up, drops predicted
  samples; decision 0003), `TabletInjector` (posts to the HID tap,
  `isTrusted`), `PenInjectionController` (map → build → post; releases
  the pen on session end; trust cached and refreshed by the host).
- Executables: `nib-inject-demo` (pressure-ramp S-curve, tests injection
  without an iPad), `nib-receive` (prints received samples, tests transport
  without NibMac).

## Apps

- `Apps/NibPad` — full-screen black `PenCaptureView`: Pencil-only touches
  with coalesced/predicted samples, hover via `UIHoverGestureRecognizer`,
  debounced proximity exit, eraser toggle via `UIPencilInteraction`,
  dimmed screen + idle timer off, three-finger-tap debug HUD (pressure,
  angles, rate, link state, fading trace). Sends through `NetworkSink`.
- `Apps/NibMac` — `MenuBarExtra` (`LSUIElement`): status, Accessibility
  onboarding, display picker (persisted), Allow/Deny prompt per iPad
  (optionally remembered by device name — not authentication).

## Build and checks

- `project.yml` — XcodeGen; `Nib.xcodeproj` is generated, not committed.
- `scripts/verify.sh` — workflow check, `swift format lint`, `swift test`,
  unsigned builds of both apps.
