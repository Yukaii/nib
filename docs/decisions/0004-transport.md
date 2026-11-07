# 0004 — Transport: Bonjour TCP control + UDP samples

Date: 2026-11-07 · Status: accepted

## Context

Pen samples arrive at 240 Hz and are useless when late; a lost `move` is
better skipped than waited for. Session setup (version check, geometry)
must be reliable. Both ends have Network.framework.

## Decision

- **Discovery:** the Mac advertises `_nib._tcp` with `NWListener`
  (service name = Mac's computer name). The iPad browses with `NWBrowser`
  and connects to the first (later: chosen) result.
- **Control channel (TCP):** each message is a 4-byte little-endian length
  followed by a JSON-encoded `ControlMessage`. Max 64 KiB; larger is a
  protocol error that closes the connection.
  - iPad → Mac `hello { protocolVersion, appVersion, deviceName,
    surfaceWidth, surfaceHeight }` (surface in points, current orientation).
  - Mac → iPad `helloAck { accepted, reason?, udpPort, displayWidth,
    displayHeight }` (target display in points, for letterboxing).
  - iPad → Mac `geometry { surfaceWidth, surfaceHeight }` on rotation.
  - Either side `ping` every 1 s; no traffic for 3 s = session lost.
- **Samples (UDP):** one 40-byte `PenSample` per datagram (decision 0002),
  sent to the Mac's control-connection host on `udpPort`. The Mac accepts
  datagrams only from that host while the session is open, and drops
  samples whose sequence is not newer than the last accepted one.
- **Loss of state transitions:** the iPad sends each `down`, `up`,
  `cancel` and `proximityExit` sample three times (same sequence; the
  copies are dropped as not-newer). The Mac injector also repairs
  missing transitions (task 0003).
- **Acceptance:** the Mac receiver asks an `accept(hello)` hook before
  answering; the host app shows a prompt (task 0006). Version mismatch is
  rejected with a reason the iPad displays.

## Consequences

- One iPad per Mac at a time in M1.
- No encryption or pairing yet: anyone on the LAN who is accepted can move
  the pointer. Pairing / TLS-PSK is an M3 item.
- A wired USB-C path (M2) can reuse the control messages and framing.
