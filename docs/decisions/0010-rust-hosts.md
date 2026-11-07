# 0010 — Windows and Linux hosts in Rust; the Mac host stays Swift

Date: 2026-11-07 · Status: accepted (supersedes the "no Linux/Windows host"
consequence of 0001)

## Context

The iPad app works with any host that speaks the protocol. Users ask for
Windows and Linux. Swift on those platforms is possible but has a thin
ecosystem for input injection, tray apps and packaging; Rust has mature
crates and is the usual choice for input daemons.

## Decision

- Windows and Linux hosts are written in Rust, in `Hosts/` (Cargo
  workspace): a platform-neutral `nib-core` crate (protocol, mapping, jitter
  buffer, key-code tables) plus one crate per OS for injection and UI.
- Injection: Linux `uinput` virtual tablet (`ABS_X/Y`, `ABS_PRESSURE`,
  `ABS_TILT_X/Y`, `BTN_TOOL_PEN`/`BTN_TOOL_RUBBER`); Windows
  `InjectSyntheticPointerInput` with `PT_PEN` (pressure, tilt, eraser).
- The Mac host stays Swift (`NibMac` + `NibCore`): it is done, native, and
  uses CGEvent APIs best reached from Swift. No rewrite.
- Both implementations must pass the same `protocol/vectors` (0008). The
  protocol spec, not the Swift code, is the contract.

## Consequences

- Two implementations of the receive side; vectors keep them in step.
- `scripts/verify.sh` gains `cargo fmt --check`, `cargo clippy -D warnings`
  and `cargo test` once `Hosts/` exists (M5).
- Bonjour on Linux needs Avahi (or a pure-Rust mDNS crate); Windows has
  native DNS-SD. Chosen in the M5 spikes.
