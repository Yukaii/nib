---
id: "0019"
title: CI — GitHub Actions runs verify; FUNDING.yml
status: doing
milestone: M3
depends: []
---

## Goal

Every push and pull request to `main` runs `scripts/verify.sh` on a macOS
runner. The repo shows a GitHub Sponsors button.

## Context

- `scripts/verify.sh` needs Xcode with Swift 6 (`swift format`), XcodeGen and
  the iOS SDK. It builds without signing (`CODE_SIGNING_ALLOWED=NO`).
- Workflow file: `.github/workflows/verify.yml`.
  - `runs-on: macos-15` (or newer if needed). Select the newest Xcode on the
    runner with `sudo xcode-select`, or pin one with a comment explaining why.
  - `brew install xcodegen`.
  - Cache `Packages/NibCore/.build`, keyed on `Package.resolved`/sources hash.
  - Run `scripts/verify.sh`.
  - `concurrency` group that cancels superseded runs on the same ref.
  - Minimal `permissions: contents: read`.
- If verify fails on the runner only because of the environment (e.g. no
  `swift format` in that Xcode), fix the environment in the workflow, not by
  weakening verify. If that's impossible, stop and explain in Handoff.
- `.github/FUNDING.yml` with `github: Yukaii`.
- README: a CI status badge next to the title.
- You can't run the workflow locally. Validate the YAML (`ruby -ryaml -e` or
  `actionlint` if installed) and say in Handoff that the first real run
  happens after the orchestrator pushes.

## Acceptance

- [ ] `.github/workflows/verify.yml` parses as YAML and runs verify on
  `push` to main and on `pull_request`.
- [ ] `.github/FUNDING.yml` exists.
- [ ] README has the badge.
- [ ] `scripts/verify.sh` passes locally.

## Out of scope

- Signing, notarization, release builds (M4).
- Pushing to GitHub.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
