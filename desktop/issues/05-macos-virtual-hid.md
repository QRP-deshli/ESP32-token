---
title: "macOS: virtual FIDO device (research, then prototype)"
labels: desktop,macos,research
---
## Why

Linux uses `/dev/uhid`; macOS has no such file. Creating a virtual HID device on macOS goes through Apple APIs that may
need an entitlement or a system extension. This is the hardest part of macOS support and needs a decision first.

## Where to look

Same as issue 03: `FIDO_REPORT_DESC`, `uhid_create2`, `uhid_input`, `Bridge.on_uhid_event`, `Bridge.on_serial_readable` in
`desktop/common/ctaphid_serial_bridge.py`. Any backend only has to move 64-byte CTAPHID reports in both directions.

## What to do (research first, write the decision in this issue)

Evaluate (starting points from my understanding, please verify each):

1. **CoreHID `HIDVirtualDevice`** (recent macOS versions) and/or **`IOHIDUserDevice`** (IOKit): create a user-space virtual
   HID device. Check which entitlement is required, whether a free developer account is enough, and what changes for
   development builds.
2. **DriverKit `IOUserHIDDevice`** (a system extension): heavier, needs installation approval by the user and signing.

Python cannot call these directly; a likely design is a small Swift/Objective-C helper that the Python bridge talks to over
a pipe or local socket, passing 64-byte reports. Decide and prototype it.

Also check how browsers on macOS reach security keys (HID through IOKit), so the virtual device is visible to them.

## Acceptance criteria

- A short written comparison and the decision.
- A working prototype: registration and login on https://www.token2.com/tools/fido2-demo in Chrome (and ideally Safari)
  with the fingerprint touch.
- Documented install steps, entitlements/signing needed, and how to remove it.
