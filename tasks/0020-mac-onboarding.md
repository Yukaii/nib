---
id: "0020"
title: Mac onboarding — setup window, Accessibility relaunch, pressure test
status: doing
milestone: M3
depends: []
---

## Goal

On first launch NibMac opens a setup window. It walks the user through
Accessibility permission (and relaunches itself once the permission is
granted), shows how to get the iPad app, waits for the iPad, and ends with a
test canvas where the user sees their pressure stroke. The window can be
reopened from the menu. Launch at login is available.

## Context

- Today NibMac is a `MenuBarExtra` only (`Apps/NibMac/NibMacApp.swift`). The
  README's "First run" section is what a user has to do by hand now. This task
  replaces it with UI. Follow AGENTS.md "Product quality bar".
- Add a SwiftUI `Window` scene (id `setup`) with these steps; the current step
  is derived from live state:
  1. **Welcome**: one sentence on what Nib does.
  2. **Accessibility**: why it's needed; a button that prompts and opens the
     System Settings pane (the existing `requestAccessibility`). Granting while
     running needs a relaunch (PLAN M1 note). When trust flips to granted, show
     "Nib needs to restart to finish" and a **Restart Nib** button. The button
     relaunches the app (`NSWorkspace.openApplication` on
     `Bundle.main.bundleURL` with `createsNewApplicationInstance`, then
     terminate). On the next launch the step shows as done.
  3. **Get Nib on your iPad**: a QR code (CoreImage `CIQRCodeGenerator`) and
     the link. URL constant: the repo README for now
     (`https://github.com/Yukaii/nib#install`), in one place so M4 can swap it.
  4. **Connect**: "Open Nib on your iPad on the same Wi-Fi, or plug in with
     USB-C". Shows live status and the iPad name when connected.
  5. **Try it**: an `NSView` canvas that draws incoming tablet events.
     Override `tabletPoint`/`mouseDragged`; read `event.pressure`. Stroke
     width follows pressure, and the current pressure value shows as a number.
     A "Looks good" button finishes setup (persist `setupCompleted`).
- Open the window automatically while `setupCompleted` is false, bringing it to
  the front (`NSApp.activate`). Add a menu item **Setup…** that reopens it
  any time.
- **Launch at login**: a menu toggle using `SMAppService.mainApp`
  (register/unregister, reflect status). Off by default; offer it on the last
  setup step.
- Remove the `try!` in `PenLinkReceiver()` construction. If the receiver can't
  start, the menu and the Connect step show a plain error with a retry.
- Put the step logic (derived from {trusted, needsRestart, connected,
  setupCompleted}) in NibCore as a pure type without AppKit, with tests.

## Acceptance

- [ ] Tests for the step logic: untrusted → accessibility; granted during
  this run → restart; trusted + not connected → connect;
  connected → try it; completed → window not auto-opened.
- [ ] No `try!` left in `Apps/NibMac`.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual checks written in Handoff (fresh `defaults delete
  dev.yukai.nib.mac`; `tccutil reset Accessibility dev.yukai.nib.mac`; walk
  all steps; verify thin→thick stroke on the canvas; launch-at-login toggle
  survives relaunch). Say whether you ran them.

## Out of scope

- Pairing codes (later M3 task), settings window / active area (later M3).
- iPad-side changes.
- Visual polish beyond clean system SwiftUI (`Form`/`GroupBox`, SF Symbols).

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
