# 0009 — Distribution: notarized DMG (Mac), App Store (iPad)

Date: 2026-11-07 · Status: accepted

## Context

Nib becomes a free, open-source product (MIT, GitHub Sponsors). The Mac
host posts `CGEvent`s to the HID tap and needs Accessibility permission,
neither of which works in the Mac App Store sandbox. The iPad app has no
non-App-Store way to reach normal users.

## Decision

- **Mac:** Developer ID signed, hardened runtime, **not sandboxed**,
  notarized and stapled, shipped as a DMG on GitHub Releases. Built in CI from
  a tag; signing secrets live only in CI secrets.
- **iPad:** free App Store app, TestFlight for betas. Building from source
  with a personal team stays documented for contributors.
- **Updates:** the Mac app must be able to tell the user about a newer
  release (mechanism chosen in M4). Mismatched app versions are caught by the
  protocol handshake (0008) with a readable message.
- **Money:** no paid tier, no licensing code. Sponsors link in the README,
  `.github/FUNDING.yml` and an unobtrusive About item.

## Consequences

- No team IDs, certificates or profiles in the repo (AGENTS ground rules).
- App Store review applies to the iPad app: no private API, clear Local
  Network purpose string, onboarding that works without the Mac app present.
- Mac App Store is not a target; revisit only if Apple changes the rules.
