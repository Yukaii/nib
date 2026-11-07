# 0011 — Pairing by numeric comparison; app-layer AEAD sessions

Date: 2026-11-07 · Status: accepted (user confirmed numeric comparison; USB pairs too)

## Context

Today the Mac allows an iPad by remembered device ID; traffic is plaintext,
so anyone on the LAN can spoof an allowed iPad and move the pointer. The
product needs real pairing and encrypted, authenticated sessions. Constraints:
no third-party Swift dependencies (CryptoKit is fine), and the Rust hosts
(0010) must implement the same thing. rustls has no external-PSK TLS 1.3, so
Network.framework TLS-PSK would force OpenSSL on Windows/Linux.

## Decision

- **Pairing (once per iPad–host pair), Bluetooth-style numeric comparison.**
  iPad and host exchange X25519 public keys and 32-byte nonces over the
  control channel. Both derive the same 6-digit code from a hash of the full
  transcript and show it. **Commit first:** `pairRequest` carries the iPad's
  key and a commitment `SHA256("nib-commit" ‖ deviceID ‖ pkD ‖ nD)`, not `nD`
  itself (exact length-prefixed encoding: `docs/protocol.md`, which is
  normative over this record). Both IDs are also in the transcript.
  `pairResponse` carries the host's key and `nH`. Only then does `pairReveal`
  send `nD`, and the host checks it against the commitment. Without this, the
  side that sends its nonce last can try 10⁶ nonces offline until the codes
  match (amended 2026-11-07 after review of 0022). The user
  confirms on the host ("Pair" button) and on the iPad; either side may
  cancel. Then both store `pairKey = HKDF-SHA256(ECDH secret, transcript)`
  keyed by the peer's ID (`deviceID` on the host, a new stable `hostID` on
  the iPad). A MITM has a 1-in-10⁶ chance per attempt, and every attempt
  needs the user to confirm a code.
- **Hello proofs** use distinct labels per direction. The host's proof binds
  *both* nonces (`"nib-ack" ‖ hostID ‖ nD ‖ nH`; labels are prefix-free), so a recorded
  helloAck can't be replayed to the iPad. A replayed iPad hello gets no usable
  session, because session keys need the fresh host nonce (below).
- **Sessions.** `hello` and `helloAck` carry fresh 32-byte nonces. Session
  keys come from `HKDF(pairKey, nonces)`, one per direction. Every control
  frame and every sample after `helloAck` is ChaCha20-Poly1305 sealed (nonce
  derived from a per-direction counter; for UDP, from the sample sequence).
  A frame that fails to open is dropped. The host accepts unpaired iPads only
  into the pairing flow.
- **Availability is a non-goal** against an active LAN or USB attacker, who can
  always flood or reset connections. Guarantees: no impersonation, no pairing
  without both users confirming, and a bounded rate of pairing prompts (3
  failed/cancelled pairings → 60 s refusal). No idle timers or busy queues
  beyond that (simplified 2026-11-07 after the 0022 round-4 review).
- **Keys at rest:** Keychain on both Apple platforms (the OS credential
  store on Windows/Linux). "Forget this iPad" / "Forget this Mac" delete them.
- **USB** uses the same sessions (the cable is not trusted). Spec and
  vectors cover pairing and sealed frames with fixed keys and nonces.

## Consequences

- Breaking for unreleased v2 builds only; done before the 1.0 freeze.
- 16-byte tag per sample (40 → 56 bytes + 8-byte header): negligible at 240 Hz.
- Primitives exist in CryptoKit and in RustCrypto (`x25519-dalek`,
  `chacha20poly1305`, `hkdf`), so no OpenSSL.
- We own a small handshake (ECDH + SAS + HKDF + AEAD, no new primitives),
  so it needs careful review and test vectors.
