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
hello. One session is allowed at a time; another sender receives `reason:
"busy"`.

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
three pairing messages are:

```json
{"type":"pairRequest","pairRequest":{"deviceID":"…","deviceName":"iPad Pro","publicKey":"base64","nonce":"base64"}}
{"type":"pairResponse","pairResponse":{"hostID":"…","hostName":"Studio Mac","publicKey":"base64","nonce":"base64"}}
{"type":"pairResult","pairResult":{"accepted":true}}
```

`publicKey` is a 32-byte X25519 public key and `nonce` is a fresh 32-byte
random value, both encoded as base64. The transcript is the byte
concatenation, in this exact order: device public key, host public key,
device nonce, host nonce. The displayed six-digit code is
`SHA256(UTF8("nib-pair") ‖ transcript)`, interpreted as the first four bytes
big-endian, modulo 1,000,000, and zero-padded. Both users must confirm the
same code. A cancel or timeout discards the ephemeral key and nonce and stores
nothing.

The stored pairing key is
`HKDF-SHA256(ikm: X25519 shared secret, salt: SHA256(transcript),
info: UTF8("nib-pair-key"), output: 32 bytes)`. It is stored by the peer ID.

After pairing, `hello` includes fresh base64 `nonce` and `proof` fields:

```json
{"type":"hello","hello":{"protocolVersion":2,"appVersion":"0.3.0","deviceID":"…","deviceName":"iPad Pro","surfaceWidth":1024,"surfaceHeight":768,"nonce":"base64","proof":"base64"}}
```

The proof is `HMAC-SHA256(pairKey, UTF8("nib-hello") ‖ UTF8(deviceID) ‖ nonce)`.
The accepting host includes its fresh base64 `nonce` and `proof` in
`helloAck`, using its stable `hostID` in the same formula. Each side verifies
the other proof with a constant-time HMAC comparison. Missing or invalid
proofs are rejected with a next step to pair again. Frame and sample
encryption begins in the subsequent encrypted-sessions version.

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
