# Security

Nib pairs an iPad with a Mac and then encrypts every session. Its pairing and
session handshake is described in
[decision 0011](docs/decisions/0011-pairing-and-encryption.md) and specified in
[`docs/protocol.md`](docs/protocol.md), with test vectors in
[`protocol/vectors/`](protocol/vectors/).

## Reporting a vulnerability

Please report security issues **privately** through GitHub's
[private vulnerability reporting](https://github.com/Yukaii/nib/security/advisories/new),
not in public issues. Include the version of both apps, the transport (Wi-Fi
or USB), and steps to reproduce.

## Scope

In scope: pairing, session encryption and authentication, anything that lets
another device inject input into a paired Mac or read Pencil data.

Out of scope: denial of service by an attacker on the same network or cable
(Nib does not try to prevent this; see decision 0011).
