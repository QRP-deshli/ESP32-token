---
title: "Epic: Windows and macOS support for the desktop side"
labels: desktop,windows,macos,enhancement
---
## Context

The token is an ESP32-C6 that speaks CTAPHID over its native USB-Serial/JTAG port. The PC runs a **bridge** that (1) talks
to that serial port and (2) shows a **virtual USB HID FIDO device** to the OS so browsers and libfido2 can use it. Today
this only works on **Linux** (`/dev/uhid`, `termios`, udev, `systemctl`...). The firmware does **not** need to change.

Read first: `desktop/README.md`, then the top-level `README.md` (Part A, steps 5 to 8).

## Definition of done (per OS: Windows, macOS)

With the unchanged firmware and the same hardware (ESP32-C6-DevKitC-1 plus the fingerprint module):

- [ ] the token is found automatically (no hard-coded port)
- [ ] `fpctl` works: `status`, `enroll`, `test`, `delete`
- [ ] registration and login work in a browser on https://www.token2.com/tools/fido2-demo with a PIN set and a
      fingerprint touch (the bridge/OS shows when to touch the sensor)
- [ ] helper scripts exist in `desktop/windows/` / `desktop/mac/` (see issue 06)
- [ ] host tests run in CI on Linux, Windows and macOS (see issue 08)
- [ ] docs per OS (see issue 09)

## Child issues

(The numbers are the file prefixes in `desktop/issues/`; GitHub assigns its own numbers when the issues are filed, so edit this list to link the real issues afterwards.)

1. Refactor: separate OS-specific code from the protocol code
2. Windows: serial port access and token detection
3. Windows: virtual FIDO device (research, then prototype)
4. macOS: serial port access and token detection
5. macOS: virtual FIDO device (research, then prototype)
6. Helper scripts for Windows and macOS
7. (optional) Let `fpctl` work while the bridge is running
8. Cross-platform tests and CI
9. Documentation for Windows and macOS
10. (discussion) Options that remove the need for the bridge

## Out of scope

Firmware changes (except if issue 10 is chosen), Linux behaviour (must not regress), flash encryption/secure boot.
