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

- **iPad edge margin (user request, 2026-11-08).** The iPad's edges are
  hard to reach with the Pencil, so the user can't trigger screen-edge things
  such as the auto-hidden Dock. Add **Edge margin** (0–15% of the iPad, default
  0): the inner area of the iPad maps onto the whole target area, and touches
  in the margin pin to the target's edge, so the target's last pixel is
  reachable with the Pencil comfortably inside the iPad edge. Apply it to the
  normalized iPad position *before* the existing keep/stretch mapping:
  `x' = clamp((x - m) / (1 - 2m))`, same for y. It lives in
  `MappingSettings` (host-only, no protocol change), applies live, and the
  preview shows it (e.g. a caption plus a small iPad outline with the inner
  area marked). Tests: with m = 0.1, iPad x = 0.1 → left edge, 0.9 → right
  edge, 0.05 → still left edge, 0.5 → centre; works with keep and stretch,
  with a sub-rect, and with a multi-display union.

## Acceptance

- [ ] Tests for `MappingSettings` round-trip and for the mapper cases above,
  including stretch vs keep-proportions on a 4:3 iPad surface into a 16:9
  display and a multi-display union with a display at negative x.
- [ ] Test: a stored display UUID that is absent resolves to main; present
  again resolves back.
- [ ] Edge-margin tests above pass.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual (user, `scripts/install-devices.sh mac`): Settings… opens in
  front; pick a region and see strokes in Krita stay inside it; toggle
  proportions mid-stroke without restarting; set Edge margin to ~8% and reveal
  the auto-hidden Dock by moving the Pencil to the bottom without reaching the
  iPad's edge; if a second display is
  available, choose it and then All displays; relaunch keeps the choice.

## Out of scope

- iPad-side settings (0028). Protocol changes.

## Handoff

```
Branch/commit: t3/fix-mac-settings-window @ 0daf0dddbc61cf1e01cfc394acfe1f0b1ae6b587
Verify: verify: ok (Test run with 200 tests; NibMac + NibPad built)
Done:
- Added follow-main migration/defaults, resilient decoding and clamped active areas, plus pure preview↔normalized geometry shared with display resolution.
- Fixed selected-display previews, live whole-box dragging, 20 pt resize handle, centered 80% default sub-area, missing-display picker fallback, and launch-at-login errors in Settings.
- Removed the unused displayChanged path while keeping mapping updates on the injection worker queue and the allocation-free sample path intact.
- Added mapper, preview geometry, migration compatibility, decode-clamp, negative-origin, edge, and stretch tests.
Manual checks: Not run. Run `scripts/install-devices.sh mac`; verify **Settings… opens in front while another app (e.g. Krita) is frontmost**, select an active area and draw in Krita to confirm strokes stay inside it; toggle proportions during a stroke; with a second display select it and then All displays; relaunch Nib and confirm the selection persists. The second-display portion is optional when no second display is available.
Not done / risks: Hardware Krita verification remains with the user.
```
