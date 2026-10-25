---
title: "Windows: virtual FIDO device (research, then prototype)"
labels: desktop,windows,research
---
## Why

On Linux the bridge creates a virtual USB HID device through `/dev/uhid`. Windows has no equivalent that a normal user
program can use, so browsers and libfido2 would not see the token. This is the hardest part of Windows support and needs
a decision first.

## Where to look

`desktop/common/ctaphid_serial_bridge.py`: `FIDO_REPORT_DESC` (standard FIDO HID descriptor: usage page 0xF1D0, 64-byte
input/output reports, no report ID), `uhid_create2`, `uhid_input`, `Bridge.on_uhid_event` (OS to token),
`Bridge.on_serial_readable` (token to OS). The serial frames carry the 64-byte CTAPHID reports unchanged, so any backend
only has to move 64-byte reports in both directions.

## What to do (research first, write the decision in this issue)

Evaluate and record pros/cons, effort and signing requirements of the options below (these are starting points from my
understanding, please verify each):

1. **Windows WebAuthn plugin authenticator API** (the passkey-provider plugin model in recent Windows 11 builds, via
   `webauthn.dll`). The browser would call the plugin instead of seeing a HID device. It receives CTAP2/CBOR requests, so
   the bridge would need to wrap them in CTAPHID frames for the token. Check which Windows versions support it and what
   registration it needs.
2. **A virtual HID device through a driver** (Virtual HID Framework, VHF, or a UMDF/KMDF driver). Needs a driver and
   signing (test-signing is fine for development).
3. **A third-party virtual HID/USB-over-IP component**, if one is acceptable.

Then prototype the chosen option end to end with `fido2-token -L`-style enumeration and a browser registration.

Note: Windows restricts direct access to FIDO HID devices to the OS WebAuthn service for non-admin apps, which affects how
`libfido2` tools and browsers talk to the device. Document what you find.

## Acceptance criteria

- A short written comparison of the options and the decision.
- A working prototype: registration and login on https://www.token2.com/tools/fido2-demo in Edge or Chrome with the
  fingerprint touch.
- Documented install/uninstall steps and what needs administrator rights.
