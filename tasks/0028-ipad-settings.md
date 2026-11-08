---
id: "0028"
title: iPad settings — sectioned panel, plain wording, Advanced for debug
status: review
milestone: M3
depends: []
---

## Goal

The iPad companion panel (four-finger tap) is a clear, sectioned settings
screen that a new user understands without the README. Debug tools are
tucked into Advanced, and every pairing/connection message reads naturally.

## Context

- Today `Apps/NibPad/CompanionPanel.swift` is one long scroll view. In order:
  - pressure (presets, soft/firm, min/max, curve, test strip);
  - profiles;
  - a **Debug HUD** toggle;
  - Change Mac, Forget this Mac, Show introduction again;
  - edge brightness.
  Profile editing lives in `ProfileEditor.swift`. Settings are `PadSettings`
  (NibCore, persisted by `PadSettingsStore`).
- Restructure into a `NavigationStack` + `List`/`Form` with these sections
  (each a row or a pushed page):
  - **Connection** — status line (plain words from `PenLinkState`), which Mac,
    via cable or Wi-Fi; Change Mac; Forget this Mac.
  - **Pen** — pressure presets, curve sliders with the preview, the test strip;
    the "this Pencil has no pressure" warning when it applies.
  - **Profiles** — current list plus editor (reuse `ProfileEditor`), with the
    active profile marked.
  - **Gestures** — the gesture options that apply to all profiles, if any are
    global today; otherwise a short explanation pointing to Profiles.
    Don't duplicate per-profile settings.
  - **Display** — edge-control brightness (live preview: the edge controls
    stay visible while the slider moves).
  - **Advanced** — Debug HUD, app version and build, Show introduction again,
    "Reset all settings" (confirmation; keeps the pairing key).
- **Wording** (AGENTS.md "Product quality bar"): no raw enums or link-state
  strings anywhere. Fix the pairing switch message: the app shows transport
  switches through the failure path, so the user reads "Pairing could not
  finish: Switched to the cable. Tap Pair to continue." Give `.failed` and a
  neutral "notice" distinct presentation (e.g. a new `PairingTransportEvent`
  case or a flag) so it reads "Switched to the cable. Tap Pair to continue."
  Review every user-facing string in `CompanionPanel`, `OnboardingView`,
  `ProfileEditor` and the pairing sheet.
- Settings changes apply live and persist (they already do through
  `PadSettingsStore`; keep that).
- iPad mini portrait and landscape must both fit without clipping. Dark
  appearance, as today.
- Keep pure logic (e.g. the status-line text, the reset behaviour) in NibCore
  with tests.

## Acceptance

- [ ] Tests: status-line text for each `PenLinkState` (USB/Wi-Fi/searching/
  rejected); "Reset all settings" restores defaults but keeps the pairing key
  and device ID; the switch notice is not presented as a failure.
- [ ] `grep -rn "Link:\|Debug HUD" Apps/NibPad` finds Debug HUD only under
  Advanced; no raw link-state text in the UI.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual (user, `scripts/install-devices.sh pad`): open the panel, visit
  every section in portrait and landscape; change pressure and see the test
  strip update; edit a profile; Advanced → Reset all settings → still paired.

## Out of scope

- Mac settings (task 0029). Protocol changes. New features beyond moving and
  wording what exists.

## Handoff

```
Branch/commit: `t3/ipad-settings` @ `23ee20782f220c407d3e217a5c4814e6554506d2`
Verify: `verify: ok (Test run with 194 tests; NibMac + NibPad built)`
Done:
- Replaced the companion scroll view with a dark NavigationStack/List organized into Connection, Pen, Profiles, Gestures, Display and Advanced.
- Added live persisted reset-to-defaults logic that leaves pairing and device identity untouched, with deterministic status and reset tests.
- Added a neutral pairing transport notice so cable switching is not shown as a failure; pairing errors remain distinct.
- Kept pressure capture and profile editing behavior intact while making status and connection wording plain.
Manual checks: Not run. User should run `scripts/install-devices.sh pad`, open the four-finger panel, visit every section in portrait and landscape, change pressure and verify the test strip, edit a profile, then use Advanced → Reset all settings and confirm the Mac remains paired.
Not done / risks: Full on-device UI and edge-control live preview still need the user’s iPad check. `Apps/NibMac/NibMacApp.swift` has a small exhaustive-switch notice case because the shared event enum is used by both apps; task 0029 can refine its Mac presentation.
```
