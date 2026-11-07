# Architecture

What exists now. Decisions live in `docs/decisions/`.

```
iPad (NibPad)                         Mac (NibMac, menu bar)
UIKit pen capture  ──PenSample──▶  receiver ─▶ map to display ─▶ CGEvent tablet events
black screen        40-byte pkts       (Network.framework)         (Accessibility)
```

- `Packages/NibCore` — shared, platform-agnostic where possible.
  - `PenSample` — the one hot-path message (decision 0002).
  - `PenLinkReceiver` accepts one iPad session, exposes geometry and samples,
    and includes the selected display size in its hello acknowledgement.
  - `DisplayMapper` preserves the display aspect ratio using a centered active
    area and clamps dead-band samples to the display edge.
  - macOS-only `PenInjectionController` feeds mapped samples through
    `TabletEventBuilder` and `TabletInjector`, preserving tablet pressure and
    releasing any held button when a session ends.
- `Apps/NibPad` — SwiftUI shell, black full-screen view.
- `Apps/NibMac` — `MenuBarExtra` host. It prompts for each iPad (with an
  optional remembered device-name decision), lets the user choose a display,
  tracks display changes, and provides Accessibility onboarding.
- `project.yml` — XcodeGen; `Nib.xcodeproj` is generated, not committed.
- `scripts/verify.sh` — workflow check, `swift format lint`, `swift test`,
  unsigned builds of both apps.
