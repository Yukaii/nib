---
id: "0017"
title: Protocol v2 — handshake with host info, capabilities and device ID
status: review
milestone: M3
depends: ["0016"]
---

## Goal

Both sides use `controlVersion = 2`. The Mac answers `hello` with its platform,
name, version and capabilities. The iPad identifies itself by a stable device
ID and reads app versions from the bundle. Unknown control messages no longer
drop the session. A v1 app and a v2 app refuse each other with a readable
reason.

## Context

- Read `docs/decisions/0008-protocol-v2.md` (versions, hello/helloAck, front
  app, forward compatibility) and 0004/0005 (TCP and USB control framing).
- `ControlMessage.swift`: add `ProtocolVersion.control = 2`, kept separate from
  `PenSample.version` (stays 1). `Hello` gains `deviceID: String` (UUID).
  `HelloAck` gains `host: HostInfo?`, where
  `HostInfo { platform: HostPlatform, name, appVersion, capabilities: [String] }`.
  Reuse the `HostPlatform` from 0016. Use string constants for capabilities;
  the iPad must not fail on a capability string it doesn't know.
- `frontApp { bundleID }` → `frontApp { appID }`. `PadSettings.Profile.bundleIDPrefixes`
  → `appIDPrefixes`, and stored settings migrate (decode the old key).
- **Forward compatibility.** `ControlFramer` currently throws `.malformed` when
  a JSON body has an unknown `type`. It must skip that message (return nothing
  for it, keep the buffer consistent) and keep decoding. A body that isn't
  JSON, or a known type with missing fields, is still malformed. This applies
  to the TCP path and to the USB `StreamFramer` path.
- Version check (`ReceiverSession` in `PenLink.swift`, plus the USB path):
  compare `hello.protocolVersion` with `ProtocolVersion.control`. The reason
  says which app to update. Example: "This Mac runs Nib 0.2 (protocol 2).
  Update Nib on your iPad."
- Mac (`NibMacApp.swift`): send `HostInfo` with platform `macos`, the computer
  name, `CFBundleShortVersionString`, and all v2 capabilities that NibMac
  actually supports. Remember accepted iPads by `deviceID`, not by name.
  Existing name-based entries can be dropped; the user is asked once more.
- iPad (`NibPadApp.swift`): the `deviceID` is generated once and persisted.
  `appVersion` comes from the bundle (remove the three `"0.1.0"` literals,
  including the default in `PenLink.swift`). Store the received `HostInfo`.
  The companion panel shows "Connected to <name> (macOS, Nib x.y)". The profile
  editor hides the native zoom/rotate options when the host lacks
  `zoomNative` / `rotateNative`, and in that case gestures fall back to
  `modifierScroll`. Key names use the host's platform (0016).
- From 0016 review: with a macOS host, the button editor shows one ⌘ toggle
  (hide **Meta**, since it duplicates Primary there). On windows/linux,
  `primary` + `control` must not display as "Ctrl+Ctrl".
- `nib-receive` keeps compiling and prints the device ID.

## Acceptance

- [ ] Tests: `Hello`/`HelloAck` with `HostInfo` round-trip. A helloAck without
  `host` still decodes (nil).
- [ ] Test: `ControlFramer` fed [known, `{"type":"futureThing","x":1}`, known]
  returns the two known messages and leaves no bytes buffered. The same holds
  for the USB stream framer.
- [ ] Test: `ReceiverSession` rejects protocolVersion 1 with a reason that
  contains "Update Nib on your iPad", and accepts 2.
- [ ] Test: v1 settings with `bundleIDPrefixes` decode into `appIDPrefixes`, and
  `profile(forAppID:)` matches as before.
- [ ] `grep -rn '"0.1.0"' Apps Packages` returns nothing.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Pairing and encryption. The device ID is only an identifier for now.
- Choosing among several Macs on the iPad (task 0021).
- Spec document and vectors (task 0018).

## Handoff

```
Branch/commit: t3/handshake-v2-review-fixes @ c390fdc
Verify: verify: ok (Test run with 115 tests; NibMac + NibPad built)
Done:
- Preserved saved zoom and rotate choices offline and applied host capability fallback only when sending gestures.
- Centralized protocol mismatch reasons using the Mac's advertised app version and update direction for TCP and USB.
- Ignored unknown gesture kinds while retaining malformed-message rejection, with control and USB tests.
- Removed requested compatibility shims, deduplicated Windows/Linux modifier labels, and added platform display names.
- Added deterministic regression tests for capability policy, version directions, unknown gestures, and modifier display.
Manual checks: Real iPad/Mac handshake, remembered-device behavior, and capability fallback not run (hardware/manual UI required).
Not done / risks: USB and Wi-Fi runtime handshake were not exercised on hardware; existing Swift concurrency warnings in USB receive code remain.

