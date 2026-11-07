---
id: "0005"
title: Transport — Bonjour/TCP control and UDP sample stream
status: doing
milestone: M1
depends: ["0002", "0004"]
---

## Goal

`PenSample`s captured on the iPad arrive, in order and deduplicated, at a
receiver on the Mac over the local network, after a hello/ack handshake
that checks the protocol version and exchanges surface/display geometry.

## Context

- Design: `docs/decisions/0004-transport.md` (read it first) and
  `0002-wire-protocol.md`. Codec: `PenSample.encode()` /
  `PenSample(decoding:)` / `PenSample.isSequence(_:newerThan:)`.
- NibCore, new folder `Sources/NibCore/Transport/` (Network.framework is on
  both platforms; keep it compiling for macOS and iOS without `#if` unless
  needed):
  - `ControlMessage.swift`: `enum ControlMessage: Codable, Equatable`
    (`hello`, `helloAck`, `geometry`, `ping`) and a `ControlFramer` with
    pure `encode(_:) -> [UInt8]` and an incremental decoder that accepts
    arbitrary byte chunks and yields whole messages (throws on > 64 KiB).
  - `SampleSequencer.swift`: pure; `accept(_ sample:) -> Bool` drops
    not-newer sequences; `reset()` on new session.
  - `PenLinkSender.swift` (used by iPad): browse `_nib._tcp`, connect,
    send hello, wait for ack, open UDP to the ack's port, `send(_:)`
    samples (triple-send for down/up/cancel/proximityExit), pings,
    reconnect after loss. Publishes a `state` (searching, connecting,
    connected(macName), rejected(reason)) via a callback or
    `AsyncStream`.
  - `PenLinkReceiver.swift` (used by Mac): `NWListener` advertising
    `_nib._tcp` + a UDP listener; `accept` hook `(Hello) async -> Bool`;
    delivers accepted samples and session events (connected(hello),
    geometryChanged, disconnected) to a handler. Single session.
  - Swift 6 strict concurrency: make the Network objects live on one
    serial `DispatchQueue` or an actor; no `@unchecked Sendable` without a
    comment explaining why it is safe.
- `nib-receive` executable target (macOS) in `Packages/NibCore/Package.swift`:
  advertises, auto-accepts, prints one line per sample (`seq kind x y
  pressure`) and session events. It is the manual test tool before 0006.
- `Apps/NibPad`: replace `LoggingSink` usage in `NibPadApp` with a
  `NetworkSink` wrapping `PenLinkSender` (keep `LoggingSink` for previews);
  send hello with the capture view's size and `geometry` on size change;
  show link state in the debug HUD; when not connected, the HUD-hidden
  screen stays black (no UI).
- Do not edit `TabletEventBuilder`, `TabletInjector`, `TabletMath`,
  `NibInjectDemo` (task 0003 is in flight). `Package.swift` will conflict
  trivially with 0003's `nib-inject-demo` target; the orchestrator resolves it.

## Acceptance

- [ ] `ControlFramerTests`: round-trip every message; decoding the
      concatenation of 3 messages fed in 1-byte chunks yields the same 3;
      oversize length throws; golden test that `ping` encodes to a
      literal byte array.
- [ ] `SampleSequencerTests`: in-order accepted, duplicate and older
      dropped, wrap across `UInt32.max`, reset.
- [ ] `swift build --package-path Packages/NibCore --product nib-receive`
      succeeds.
- [ ] NibPad builds in verify with the network sink wired in.
- [ ] Manual checks written in Handoff: run `nib-receive` on the Mac, run
      NibPad on the iPad (same Wi-Fi), allow local network, draw → lines
      with rising/falling pressure print on the Mac; quit `nib-receive` →
      iPad HUD shows searching, restart → reconnects. Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Event injection, display mapping, Mac UI (task 0006). USB, pairing,
  encryption.

## Handoff

Filled in by the worker:

```
Branch/commit: t3/implement-transport-layer @ 827ff49e52ecd9b87e74dd2cc7e5ed63bbb4a749
Verify: verify: ok (Test run with 22 tests; NibMac + NibPad built)
Done:
- Added Codable TCP control messages with length framing, incremental decoding, and size protection.
- Added wrap-aware UDP sample sequencing and Network.framework sender/receiver with Bonjour discovery, handshake, geometry, retries, heartbeats, and transition triple-send.
- Added the macOS `nib-receive` executable and deterministic transport tests.
- Wired NibPad to the network sink, geometry reporting, and HUD link state while preserving capture debounce/prediction behavior.
Manual checks: Not run; requires a physical iPad, same-Wi-Fi Mac, local-network permission, and a drawing app. Steps: run `nib-receive`, launch NibPad, allow local network, draw and check pressure lines; quit/restart receiver and check searching/reconnect HUD state.
Not done / risks: Receiver currently accepts the first UDP session while one TCP session is active; pairing/encryption and display geometry values remain task 0006 scope.
```
