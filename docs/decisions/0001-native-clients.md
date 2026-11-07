# 0001 — Native iPad app and native Mac host

Date: 2026-11-07 · Status: accepted

## Context

Glass and Weylus use a browser on the iPad. Weylus has no pen pressure on
macOS at all; Glass forwards pressure but is a remote-desktop tool that
streams the screen. Nib is screen-off: there is no video to show, so the
browser's main advantage (no install) buys little, and Pointer Events in
Safari lose fidelity we need.

## Decision

- iPad: native UIKit app. `UITouch` gives `force / maximumPossibleForce`,
  `altitudeAngle`, `azimuthAngle(in:)`, coalesced touches (240 Hz on Pencil),
  predicted touches, `UIHoverGestureRecognizer` with `zOffset` (Pencil Pro on
  iPad mini 7), and `UIPencilInteraction` for double-tap / squeeze.
- Mac: native menu-bar app in Swift that posts `CGEvent`s (see 0003).
- Shared Swift package `NibCore` for the wire protocol and mapping math.

## Consequences

- Needs Xcode signing to install on the iPad (free personal team works, 7-day
  re-sign). Documented in M3.
- No Linux/Windows host. Out of scope.
