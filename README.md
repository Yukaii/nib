# Nib

Use an iPad + Apple Pencil as a screen-off drawing tablet for your Mac, with
real pen pressure in Krita, Photoshop and Affinity.

Status: early development. See `PLAN.md`.

- `Apps/NibPad` — iPad app: black screen, captures the Pencil.
- `Apps/NibMac` — Mac menu-bar app: receives samples, posts tablet events.
- `Packages/NibCore` — shared wire protocol and mapping math.

Build: `brew install xcodegen && xcodegen generate && open Nib.xcodeproj`.
