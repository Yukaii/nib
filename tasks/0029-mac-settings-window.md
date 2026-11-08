---
id: "0029"
title: Mac settings window — display, active area, multi-display
status: review
milestone: M3
depends: []
---

## Goal

NibMac has a proper Settings window. The user chooses where the Pencil
draws: one display or all displays, the whole screen or a region of it, and
whether to keep the iPad's proportions. Changes apply live while drawing and
persist.

## Context

- Mapping happens on the Mac: `Packages/NibCore/Sources/NibCore/DisplayMapper.swift`
  (aspect-locked "force proportions": the whole display is reachable; the
  iPad's extra band clamps to the edge), fed by `PenInjectionController`.
  Today the only choice is a **Display** submenu in `Apps/NibMac/NibMacApp.swift`
  (~:598), persisted as `selectedDisplayID`.
- Mapping is a **host** setting, so it needs no protocol change. Future
  Windows/Linux hosts own their own mapping (decision 0010). Don't send it over
  the wire.
- Add to NibCore a `MappingSettings` value (Codable, tested):
  - **Target**: one display (by stable identity: `CGDirectDisplayID` is not
    stable across reboots/replugs, so also store the display's UUID via
    `CGDisplayCreateUUIDFromDisplayID`, and fall back to main) or **all
    displays** (the union of their bounds in global coordinates).
  - **Area**: whole target, or a normalized sub-rectangle of it
    (0…1 x/y/w/h, minimum size 10%).
  - **Proportions**: keep proportions (today's behaviour, letterbox/pillarbox
    with the extra band clamped) or stretch to fill.
  Extend `DisplayMapper` to take the resolved rect and the proportions mode.
  Mapping math stays pure and tested: corners, centre, clamp, each mode, a
  sub-rect, multi-display union with negative origins (a display left of or
  above the main one).
- **Settings window**: a SwiftUI `Settings` scene (opened from the menu with
  "Settings…" ⌘,; menu-bar app, so activate it). Contents:
  - a display picker (names + "All displays");
  - a **live preview**: a scaled drawing of the displays with the active area
    as a rectangle the user can drag and resize (or choose "Whole screen");
  - the proportions toggle;
  - Smoothing and Launch at login (move from the menu);
  - a small "Paired iPads" list with Forget (or link to the existing menu).
  Keep the menu short: status, Settings…, Setup…, Paired iPads, Quit.
  Diagnostics toggle can move to the Settings window's Advanced area.
- Displays come and go: when the stored display is missing, fall back to main
  and say so in the window; when it returns, use it again without user
  action.
- Respect `PenInjectionWorker` threading: mapping changes are applied on its
  queue (as `displayChanged` is today), never per sample from main.

## Acceptance

- [ ] Tests for `MappingSettings` round-trip and for the mapper cases above,
  including stretch vs keep-proportions on a 4:3 iPad surface into a 16:9
  display and a multi-display union with a display at negative x.
- [ ] Test: a stored display UUID that is absent resolves to main; present
  again resolves back.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual (user, `scripts/install-devices.sh mac`): Settings… opens in
  front; pick a region and see strokes in Krita stay inside it; toggle
  proportions mid-stroke without restarting; if a second display is
  available, choose it and then All displays; relaunch keeps the choice.

## Out of scope

- iPad-side settings (0028). Mapping a sub-region of the **iPad** surface.
  Protocol changes.

## Handoff

```
Branch/commit: t3/mac-settings-window @ 2ace4f7f584ee0cd65f8f614020e92dcdcf841f3
Verify: verify: ok (Test run with 196 tests; NibMac + NibPad built)
Done:
- Added Codable host mapping settings with stable display UUID targets, all-display unions, normalized active areas, and live proportion modes.
- Extended the pure mapper and injection worker so mapping changes are applied on the worker queue without per-sample allocations or main-thread hops.
- Added a macOS Settings scene with display selection, active-area preview, proportions, smoothing, launch-at-login, diagnostics, and paired iPad controls; the menu now stays concise and activates Settings in front.
- Added mapper and settings tests for round-trips, fallback/reappearance, corners, clamp behavior, sub-rectangles, negative display origins, and stretch versus keep-proportions.
Manual checks: Not run. User: run `scripts/install-devices.sh mac`, open Settings… (⌘,), select an active area and draw in Krita to confirm strokes stay inside it; toggle proportions during a stroke; with a second display select it and then All displays; relaunch Nib and confirm the selection persists. The second-display portion is optional when no second display is available.
Not done / risks: Hardware Krita verification remains with the user; preview coordinates are a scaled overview of global display bounds.
```
