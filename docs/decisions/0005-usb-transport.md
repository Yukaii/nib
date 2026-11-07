# 0005 — USB-C mode via usbmuxd

Date: 2026-11-07 · Status: accepted

## Context

Measured on Wi-Fi (task 0007/0008): RTT ~10 ms, but sample delay variation
p95 ~80 ms with the Mac no longer the bottleneck. A cable removes Wi-Fi from
the path. Apps cannot use the CoreDevice developer tunnel; the standard
app-level path (Peertalk-style) is usbmuxd: the Mac opens a TCP connection to
a port the iPad app listens on, multiplexed over the USB cable.

## Decision

- **iPad:** NibPad listens with `NWListener` on TCP port **47811** and
  accepts only loopback peers (usbmuxd connections arrive from localhost;
  LAN peers are refused).
- **Mac:** a `UsbmuxClient` talks to `/var/run/usbmuxd` (unix socket):
  `Listen` for `Attached`/`Detached`; on attach of a USB device, `Connect`
  to port 47811 (port in network byte order). usbmux packets use a 16-byte
  little-endian header (length, version 1, message type 8 = plist, tag) and
  XML plist bodies. After a successful `Connect` result the socket is a raw
  byte stream to the iPad app.
- **Stream framing (USB only):** frames of `type: UInt8` + payload.
  `0x01` = control (the existing `ControlFramer` bytes: 4-byte LE length +
  JSON), `0x02` = one 40-byte `PenSample`. Same hello/helloAck/ping/probe
  semantics as Wi-Fi; no UDP, no triple-send (the stream is reliable).
- **Priority:** USB beats Wi-Fi. While a USB session is live the Mac answers
  Wi-Fi hellos with `busy`, and the iPad routes samples only to USB. On USB
  loss the iPad falls back to its Wi-Fi sender automatically.
- The accept prompt still applies (a USB-attached device is not implicitly
  trusted).

## Consequences

- Works with a plain USB-C cable; needs the iPad to have trusted this Mac
  (standard "Trust This Computer").
- A reliable stream can head-of-line block after loss, but USB does not lose
  packets in practice.
- Wired mode is Mac-initiated; Bonjour is not involved.
