# Architecture

What exists now. Decisions live in `docs/decisions/`.

```
iPad (NibPad)                         Mac (NibMac, menu bar)
UIKit pen capture  ──PenSample──▶  receiver ─▶ map to display ─▶ CGEvent tablet events
black screen        40-byte pkts       (Network.framework)         (Accessibility)
```

- `Packages/NibCore` — shared, platform-agnostic where possible.
  - `PenSample` — the one hot-path message (decision 0002).
  - macOS-only pieces sit behind `#if os(macOS)`.
- `Apps/NibPad` — SwiftUI shell, black full-screen view.
- `Apps/NibMac` — `MenuBarExtra` shell, `LSUIElement`.
- `project.yml` — XcodeGen; `Nib.xcodeproj` is generated, not committed.
- `scripts/verify.sh` — workflow check, `swift format lint`, `swift test`,
  unsigned builds of both apps.
