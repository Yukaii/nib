# 0003 — Inject tablet input with CGEvent tablet subtypes

Date: 2026-11-07 · Status: accepted (to be confirmed by task 0003's manual check)

## Context

Mac drawing apps read pressure from `NSEvent.pressure` / tablet fields, which
are populated only when the mouse event carries the tablet-point subtype and
the app has seen a tablet proximity event. A plain `CGEvent` mouse drag
draws with constant pressure. A DriverKit virtual HID tablet would also work
but needs a system extension, entitlements and user approval: too heavy for
M1.

## Decision

Post events to `.cghidEventTap` from the Mac host (needs Accessibility
permission):

1. On first contact / hover: `tabletProximity` event (enter), pointer type
   pen (or eraser), stable device id, capability mask with pressure + tilt.
2. While touching: `leftMouseDown` / `leftMouseDragged` / `leftMouseUp` with
   `mouseEventSubtype = tabletPoint` and `tabletEventPointPressure`,
   `tabletEventTiltX/Y`, `mouseEventPressure`, plus matching device id.
3. Hover: `mouseMoved` with tablet-point subtype and pressure 0.
4. On lift-out / timeout: `tabletProximity` (exit).

Tilt conversion (NibCore `TabletMath`, tested): with altitude θ and azimuth
φ, `tiltX = cos θ · cos φ`, `tiltY = cos θ · sin φ`, each in −1…1 (0 when
the pen is perpendicular). Sign conventions get confirmed in Krita's tablet
tester during task 0003.

## Consequences

- One-time Accessibility grant; the app must guide the user.
- If an app ignores CGEvent tablet data, fallback is a DriverKit virtual
  HID digitizer (would be a new decision).
