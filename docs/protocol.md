# Nib protocol v2

This document is the language-neutral wire contract between an iPad sender and
a host. The JSON examples are illustrative; object key order is irrelevant.
The byte strings in `protocol/vectors/` are normative examples.

## 1. Overview and versions

Nib uses two independent versions:

- The control session version is `2`, carried in `hello.protocolVersion`.
- The pen sample layout version is `1`, carried at byte offset 2 of every
  40-byte sample.

Control traffic is reliable JSON. Pen samples are fixed-size little-endian
packets. A host MUST reject a control hello with a version other than 2 and
reply with `helloAck.accepted: false` and a readable `reason`. A host MUST
reject a sample with an unsupported sample version.

Pressure is mandatory and is never listed as a capability.

## 2. Discovery

The Mac advertises the Bonjour service `_nib._tcp`. Its service name is the
Mac's computer name. The iPad browses this service and may connect to the first
result. There are currently no required TXT records.

USB mode does not use Bonjour. The Mac connects through usbmuxd to TCP port
`47811` on the iPad application.

## 3. Session

The sender opens one TCP control connection, sends `hello`, and waits for
`helloAck`. The receiver invokes its user acceptance step before accepting a
hello. One session is allowed at a time. A new connection while a session or
pairing machine is active receives `helloAck{accepted:false, reason:"busy"}`
and is closed immediately; it is not queued or counted as a pairing attempt.

Both peers send `ping` every second. Any control traffic, including a ping or
probe, refreshes the session. No traffic for 3 seconds ends the session. The
sender reconnects after a normal loss; a busy rejection is retried after about
2 seconds.

Either peer may send `probe {"sentAtNs": N}`. The peer replies with
`probeReply` carrying the same value. The sender's monotonic timestamp is used
to calculate RTT; a reply from the future is ignored. The receiver sends a
probe with each heartbeat.

Over Wi-Fi, the sender transmits `down`, `up`, `cancel`, and `proximityExit`
three times. The copies have the same sequence and the receiver drops repeats.
USB is reliable and sends each transition once.

## 4. Control framing

On TCP, each message is a four-byte unsigned little-endian length followed by
that many UTF-8 JSON bytes. The body length MUST be at least 2 and MUST NOT
exceed 65,536 bytes. A receiver buffers partial frames and may receive several
frames in one read. Invalid length, invalid UTF-8/JSON, or a malformed known
message is a protocol error and closes the connection.

On USB, prepend one byte to each frame: `0x01` means the TCP control frame
above, and `0x02` means one 40-byte pen sample. An unknown tag is an error.
USB control length limits are the same as TCP.

### Authenticated session frames

When pairing has produced a `pairKey`, the fresh authenticated hello nonces
are the session inputs. The iPad nonce is followed by the host nonce, with no
additional encoding, to form the HKDF salt. HKDF `info` is UTF-8, including
the `→` character (U+2192). Control and sample traffic use separate keys in
each direction:

```
HKDF-SHA256(pairKey, salt = nD ‖ nH, info = "nib-session control ipad→host")
HKDF-SHA256(pairKey, salt = nD ‖ nH, info = "nib-session control host→ipad")
HKDF-SHA256(pairKey, salt = nD ‖ nH, info = "nib-session sample ipad→host")
HKDF-SHA256(pairKey, salt = nD ‖ nH, info = "nib-session sample host→ipad")
```

The output length is 32 bytes. A third derivation,
`HKDF-SHA256(pairKey, salt = nD ‖ nH, info = "nib-session epoch")`, has an
8-byte output. Those eight bytes are the per-session sample epoch. The epoch
changes with a fresh authenticated hello; a sender MUST rekey before its
32-bit sample sequence wraps.

`helloAck` is the last plaintext frame in each direction. The sender arms its
session cipher immediately after writing that frame; every remaining byte in
the same read is sealed. After `helloAck`, the body of every TCP control frame (and every USB `0x01`
frame) is, byte by byte:

```
offset  size  value
0       8     unsigned control counter, little-endian
8       N     ChaCha20-Poly1305 ciphertext of the UTF-8 JSON body
8+N     16    authentication tag
```

The outer four-byte little-endian length still counts this whole body. The
12-byte AEAD nonce is four zero bytes followed by the eight-byte little-endian
counter. Counters start at zero independently in each direction; receivers
require the next counter exactly, so a replay, gap, or out-of-order frame
closes the session. The frame has no separate AAD.

An encrypted UDP sample (and a USB `0x02` frame) is, byte by byte:

```
offset  size  value
0       4     plaintext sample sequence, little-endian
4       40    ChaCha20-Poly1305 ciphertext of the PenSample bytes
44      16    authentication tag
```

Its AEAD nonce is the eight-byte session epoch followed by the four-byte
little-endian sequence. The header is authenticated by nonce selection. A
sender never seals predicted samples and never seals two different plaintexts
with one sequence; an identical re-seal is allowed for Wi-Fi triple-send.
When the next sequence would be `UInt32.max`, the sender closes the session
cleanly and reconnects, producing a fresh hello, epoch, and keys. A failed
sample open on UDP drops the datagram and counts loss; on the reliable USB
byte stream it closes the session. The legacy no-store path remains plaintext.

## 5. Control messages

Every object has a string `type` and a payload property where shown. Unknown
JSON properties MUST be ignored. Unknown `type` values MUST be skipped while
the connection remains usable.

### hello

```json
{"type":"hello","hello":{"protocolVersion":2,"appVersion":"0.3.0","deviceID":"…","deviceName":"iPad Pro","surfaceWidth":1024,"surfaceHeight":768}}
```

| Field | Type | Meaning |
|---|---|---|
| `protocolVersion` | integer | Must be 2. |
| `appVersion` | string | Sender application version. |
| `deviceID` | string | Stable per-install identifier; old senders may omit it. |
| `deviceName` | string | User-visible sender name. |
| `surfaceWidth`, `surfaceHeight` | number | Current iPad surface in points. |

### helloAck

```json
{"type":"helloAck","helloAck":{"accepted":true,"udpPort":47812,"displayWidth":2560,"displayHeight":1664,"host":{"platform":"macos","name":"Studio Mac","appVersion":"0.3.0","capabilities":["tilt","hover","keys"]}}}
```

`accepted` is required. On rejection, `reason` is a user-readable string;
other fields may be zero or absent. On acceptance, `udpPort` is the UDP port
for samples over Wi-Fi and display dimensions are points. `host` is optional
metadata with `platform` (`macos`, `windows`, or `linux`), `name`, `appVersion`,
and a string capability list.

### Pairing and authenticated hello

An iPad and Mac pair before either accepts pen input. Pairing uses the same
control messages over Wi-Fi and USB; a cable is not trusted by itself. The
four pairing messages, in order, are:

```json
{"type":"pairRequest","pairRequest":{"deviceID":"…","deviceName":"iPad Pro","publicKey":"base64","commitment":"base64"}}
{"type":"pairResponse","pairResponse":{"hostID":"…","hostName":"Studio Mac","publicKey":"base64","nonce":"base64"}}
{"type":"pairReveal","pairReveal":{"nonce":"base64"}}
{"type":"pairResult","pairResult":{"accepted":true}}
```

`publicKey` is a 32-byte X25519 public key, `nonce` is a fresh 32-byte random
value (verifiers require exactly 32 bytes), and `commitment` is
`SHA256(UTF8("nib-commit") ‖ len(deviceID) ‖ UTF8(deviceID) ‖
devicePublicKey ‖ deviceNonce)`, all encoded as base64. `len` is a 2-byte
big-endian length. The deviceID binds the commitment to one iPad so a relay
cannot relabel it. The iPad sends only the commitment first; the host replies
with its key and nonce; only then does the iPad reveal its nonce. The host
verifies the reveal against the commitment with a constant-time comparison
before deriving anything or showing a code. A mismatch fails pairing, clears
all ephemeral secrets, enters a terminal failed phase, and stores nothing.

The transcript is the byte concatenation, in this exact order: `len(deviceID)
‖ deviceID ‖ len(hostID) ‖ hostID ‖ devicePublicKey ‖ hostPublicKey ‖
deviceNonce ‖ hostNonce`, where `len` is a 2-byte big-endian length and keys
and nonces are raw 32 bytes. Both IDs are bound so a relay cannot relabel and
overwrite another iPad's key. The displayed six-digit code is
`SHA256(UTF8("nib-pair-code") ‖ transcript)`, interpreted as the first four
bytes big-endian, modulo 1,000,000, and zero-padded. Both users must confirm
the same code. A second `pairRequest` mid-flow is ignored, not a failure; an
early, duplicate or late `pairResult` from a terminal phase is ignored and
never re-fires. A cancel or a timeout (60 seconds) discards the ephemeral keys
and nonces and stores nothing.

The stored pairing key is
`HKDF-SHA256(ikm: X25519 shared secret, salt: SHA256(transcript),
info: UTF8("nib-pair-key"), output: 32 bytes)`. It is stored by the peer ID
(`deviceID` on the host, `hostID` on the iPad).

Labels are prefix-free: none of `nib-hello`, `nib-ack`, `nib-commit`,
`nib-pair-code`, `nib-pair-key` is a prefix of another, so HMAC/SHA256 domains
never collide.

First pairing stays on one connection: an unpaired iPad's unauthenticated
`hello` gets `helloAck{accepted:false, reason:"Pair with this Mac",
pairingRequired:true}` and the host keeps the connection open in a
pairing-only state. In that state only `hello`, `pairRequest`, `pairReveal`,
`pairResult` and `ping` are processed; no samples, gestures or UDP gate are
active. There is no pairing-only idle expiry: the existing 60-second pairing
machine timeout is the only pairing deadline, and a user-initiated invite may
wait as long as the user needs before tapping Pair. After the user confirms on
both sides, the iPad sends a fresh authenticated `hello` on the same
connection. USB uses the same flow over the USB stream.

When an iPad already holds a key but receives an unauthenticated
`pairingRequired` hint, it keeps the key and surfaces “Mac asks to pair again.”
The user must explicitly choose Pair again; that action deletes the old key and
starts pairing. Until then normal reconnect with backoff continues. The device
keeps pairing-only gating enabled: it accepts only `helloAck`, `pairResponse`,
`pairResult` and `ping`, and ignores pen, geometry, probe, gesture and app
messages.

After pairing, `hello` includes fresh base64 `nonce` and `proof` fields:

```json
{"type":"hello","hello":{"protocolVersion":2,"appVersion":"0.3.0","deviceID":"…","deviceName":"iPad Pro","surfaceWidth":1024,"surfaceHeight":768,"nonce":"base64","proof":"base64"}}
```

The device proof is `HMAC-SHA256(pairKey, UTF8("nib-hello") ‖
UTF8(deviceID) ‖ deviceNonce)`. The accepting host includes its fresh base64
`nonce` and `proof` in `helloAck`:

```json
{"type":"helloAck","helloAck":{"accepted":true,"udpPort":47812,"displayWidth":2560,"displayHeight":1664,"nonce":"base64","proof":"base64"}}
```

The host proof is `HMAC-SHA256(pairKey, UTF8("nib-ack") ‖
UTF8(hostID) ‖ deviceNonce ‖ hostNonce)` with a distinct label, so a recorded
ack cannot be replayed against a fresh device nonce. Each side verifies the
other proof with a constant-time HMAC comparison and requires exactly 32-byte
nonces. Missing or invalid proofs are rejected with a next step to pair again.
When a key is held, the device applies `hostInfo` and acts on a rejection
reason only after proof verification; an unauthenticated rejection is shown
but never deletes a stored key. After the authenticated `helloAck`, encrypted
session frames begin on the same connection.

After 3 failed, cancelled, or timed-out pairing machines within 5 minutes, the
host refuses new `pairRequest`s for 60 seconds with
`pairResult{accepted:false, reason:"Too many pairing attempts. Try again in a
minute."}`. Busy rejections, connection attempts, and USB plug-ins do not
count. The host stores only the bounded recent failure history needed for this
decision.

Availability against an active LAN or USB attacker is a non-goal: an attacker
can flood or reset connections. Pairing still guarantees no impersonation or
pairing without both users confirming, subject to the bounded failure limiter.

### geometry

`{"type":"geometry","geometry":{"surfaceWidth":768,"surfaceHeight":1024}}`

The sender sends this after orientation or surface-size changes.

| Field | Type | Meaning |
|---|---|---|
| `surfaceWidth`, `surfaceHeight` | number | Current sender surface in points. |

### ping, probe, and probeReply

`{"type":"ping"}` has no payload. Probe messages are
`{"type":"probe","sentAtNs":123}` and
`{"type":"probeReply","sentAtNs":123}`.

| Message | Field | Type | Meaning |
|---|---|---|---|
| `ping` | — | — | Heartbeat with no payload. |
| `probe`, `probeReply` | `sentAtNs` | unsigned integer | Monotonic timestamp echoed by the peer. |

### gesture

The payload is an object described in section 6:
`{"type":"gesture","gesture":{…}}`.

### frontApp

`{"type":"frontApp","frontApp":{"appID":"org.kde.krita","name":"Krita"}}`

`appID` is a bundle identifier on macOS, executable name on Windows, or app
identifier/`WM_CLASS` on Linux. A receiver also accepts the legacy `bundleID`
key when decoding this payload and maps it to `appID`; new encoders use
`appID`.

| Field | Type | Meaning |
|---|---|---|
| `appID` (or legacy `bundleID`) | string | Platform-specific application identifier. |
| `name` | string | User-visible application name. |

## 6. Gestures and keys

Gesture `type` values are `scroll`, `zoom`, `rotate`, `undo`, `redo`, and
`key`. Unknown gesture types MUST be skipped, including when carried inside a
known gesture control frame.

`scroll` has numeric `dx`, `dy`, and `phase`. `zoom` has numeric `scaleDelta`,
`phase`, a `modifier`, and optional `method` (`modifierScroll` or
`nativeGesture`). `rotate` has numeric `degreesDelta` and `phase`. `phase` is
`began`, `changed`, `ended`, or `cancelled`. `undo` and `redo` have no other
fields.

`key` has `chord` and `action` (`tap`, `down`, or `up`). A chord is
`{"key":"KeyZ","modifiers":["primary"]}`. `key` may be omitted for a
modifier-only chord. Key names are W3C `KeyboardEvent.code` values, such as
`KeyZ`, `Digit1`, `Space`, `BracketLeft`, `ArrowUp`, and `F5`.

Modifiers are `primary`, `control`, `alt`, `shift`, and `meta`. `modifiers` is
a set: receivers MUST ignore order and duplicates; senders SHOULD emit them in
the order listed here. `primary` maps
to Command on macOS and Ctrl on other hosts. `meta` maps to Command, Windows,
or Super respectively; `alt` maps to Option on macOS. A host ignores a key it
cannot map. It MUST release held keys and modifiers when a session ends.

## 7. Capabilities

The capability names currently defined are `tilt`, `hover`, `eraser`, `keys`,
`scroll`, `zoomModifierScroll`, `zoomNative`, `rotateNative`, `undoRedo`, and
`frontApp`. A sender hides an option or falls back when the host does not list
the corresponding capability. New capability strings are safe to ignore.

## 8. Pen sample packet

Every sample is exactly 40 bytes and uses little-endian integers and IEEE-754
binary32 floats.

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 2 | magic | `0x4E42` (`42 4E` on wire). |
| 2 | 1 | version | `1`. |
| 3 | 1 | kind | 0 hover, 1 down, 2 move, 3 up, 4 cancel, 5 proximityExit. |
| 4 | 4 | sequence | Unsigned counter, wrapping at 2^32. |
| 8 | 8 | timestamp | Sender monotonic nanoseconds. |
| 16 | 4 | x | Float32, 0…1, top-left origin. |
| 20 | 4 | y | Float32, 0…1, top-left origin. |
| 24 | 4 | pressure | Float32, 0…1; zero while hovering. |
| 28 | 4 | altitude | Float32 radians, 0 flat to π/2 perpendicular. |
| 32 | 4 | azimuth | Float32 radians, 0…2π in iPad view coordinates. |
| 36 | 2 | hoverDistance | UInt16 mapping hover z-offset 0…1 to 0…65535; zero while touching. |
| 38 | 1 | buttons | Bit 0 eraser; bit 1 barrel/squeeze. |
| 39 | 1 | flags | Bit 0 predicted; bit 1 coalesced. |

A receiver MUST reject wrong length, bad magic, unsupported version, unknown
kind, non-finite floats, or values outside the stated ranges. It MUST NOT
silently clamp invalid values. UDP samples are accepted only from the host of
the accepted control connection and only when their sequence is newer under
wrap-aware serial arithmetic. A late or duplicate sample is dropped.

## 9. Compatibility

Version 2 is additive: unknown fields, capabilities, control types, and
gesture types are ignored as described above. Removing or changing an existing
field requires a control-version decision. The sample layout has its own
version and cannot change without a sample-version bump.

For a version mismatch, the current Mac receiver formats the reason as:
`This Mac runs Nib <hostAppVersion> (protocol 2). Update Nib on your iPad.`
when the remote version is older, or `… Update Nib on your Mac.` when it is
newer. Hosts should preserve the same user-facing meaning.

The vectors in `protocol/vectors/` cover every current control and gesture
case, all sample kinds and boundary features, invalid packets, and the W3C key
translation table. A conforming implementation MUST decode every valid
vector's `framedHex` / `hex` to the values in `json` / `fields`, MUST reject
every invalid vector as stated, and MUST encode samples byte-for-byte. Control
JSON need not re-encode byte-for-byte: number formatting differs between JSON
libraries (`1024` vs `1024.0`). The Swift reference encoder does match the
vectors exactly (sorted object keys, canonical modifier order).
