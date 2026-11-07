---
id: "0011"
title: USB-C mode via usbmuxd
status: doing
milestone: M2
depends: []
---

## Goal

With the iPad plugged into the Mac by cable, Nib connects over USB
automatically, is preferred over Wi-Fi, and falls back to Wi-Fi when
unplugged. The menu line shows which transport is active.

## Context

- Design: `docs/decisions/0005-usb-transport.md` (read it first). Port
  47811, loopback-only listener on iPad, usbmuxd plist protocol on the Mac,
  type-tagged stream framing (0x01 control, 0x02 sample).
- NibCore, new files under `Transport/USB/`:
  - `UsbmuxPacket.swift` (pure): encodes and decodes the 16-byte header +
    plist body (`PropertyListSerialization`), builds the `Listen` and
    `Connect` requests (DeviceID, PortNumber = `UInt16(47811).bigEndian`
    widened as usbmuxd expects, ProgName "Nib"), and parses `Attached`,
    `Detached` and `Result` messages.
  - `StreamFramer.swift` (pure): incremental decoder of the type-tagged
    frames. It reuses `ControlFramer` for control payloads and rejects
    unknown types.
  - `UsbmuxClient.swift` (macOS): an `NWConnection` to
    `.unix(path: "/var/run/usbmuxd")` that sends `Listen`, tracks attached
    devices whose ConnectionType is USB, and opens a second usbmux
    connection with `Connect` per device. Retry the connect every 2 s
    while attached (the app may not be running yet).
  - `UsbLinkListener.swift` (iOS side, compile on both): an `NWListener`
    on 47811 that refuses non-loopback peers and runs the same
    hello/ack/ping/probe exchange over the stream.
- `PenLinkReceiver` integration: a USB session produces the same
  `onSample` (with arrival time) and `onSession` events. Keep the session
  rules: accept hook, version check, single session, 3 s heartbeat. While
  USB is live, Wi-Fi hellos get `busy`. Keep edits to `PenLink.swift`
  small and additive; task 0010 is adding gesture messages in parallel.
- NibPad: `NetworkSink` routes samples (and later control messages) to USB
  when a USB session is live, otherwise to Wi-Fi. No triple-send on USB.
- NibMac: the menu status shows `connected via USB` / `via Wi-Fi`, and the
  diagnostics line works for both. RTT probes work over USB.

## Acceptance

- [ ] `UsbmuxPacketTests`:
      - golden bytes for a `Listen` request header;
      - a `Connect` request carries the port in the expected byte order;
      - `Attached`/`Detached`/`Result` plists parse.
- [ ] `StreamFramerTests`:
      - interleaved control + sample frames fed 1 byte at a time decode in
        order;
      - an unknown type throws;
      - a truncated frame waits for more bytes.
- [ ] Loopback-only policy is a pure function and tested (127.0.0.1 / ::1
      allowed, LAN addresses refused).
- [ ] Manual checks in Handoff:
      - plug in the iPad → the menu shows `via USB` within ~3 s;
      - draw and compare the jitter p95 with Wi-Fi;
      - unplug → falls back to Wi-Fi without restarting either app.

      Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Gestures (0010), settings UI (0009), wire-format changes to `PenSample`.

## Handoff

```
Branch/commit: t3/add-usb-transport @ 46bc8f3291a61e2c73662108cab7b1f3fa27a52d
Verify: verify: ok (Test run with 55 tests; NibMac + NibPad built)
Done:
- Added usbmuxd plist packet encoding/decoding, USB stream framing, and loopback policy tests.
- Added Mac usbmuxd discovery/connect retry and iPad loopback-only USB listener.
- Routed USB samples/control and receiver events through the existing session, stats, heartbeat, and injection path; Wi-Fi remains fallback.
- Added USB/Wi-Fi menu status and deterministic transport tests.
Manual checks: Plug in iPad and confirm `via USB` within ~3 seconds, compare jitter p95 while drawing, then unplug and confirm Wi-Fi fallback; not run (no iPad/USB hardware in this environment).
Not done / risks: Hardware usbmuxd trust, cable latency, and unplug/reconnect behavior still require the manual checks above.
```
