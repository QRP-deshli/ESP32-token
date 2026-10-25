---
title: "Documentation for Windows and macOS"
labels: desktop,windows,macos,documentation
---
## Why

The top-level `README.md` is written for Ubuntu: ESP-IDF setup, `dialout` group, `ModemManager`, udev, `sudo`.

## Where to look

Top-level `README.md`: Part A steps 1 (what you need), 4 (flash), 5 to 8 (enrol, bridge, CLI test, browsers), the
troubleshooting table in step 9, Part B (daily use), "Helper scripts", "Status". Also `desktop/windows/README.md` and
`desktop/mac/README.md` (placeholders), `NOTICE.md`.

## What to do

- Per OS: how to install ESP-IDF v5.5 and flash (Windows/macOS differ from Ubuntu), the serial driver situation, how to
  find the port, permissions, the browser setup, the daily routine, a troubleshooting table in the same style as Linux.
- Replace "Linux only" wording in the top-level README (`The bridge must run on every PC...`, step 1, Status) with an
  accurate per-OS status table, only claiming what was tested on real hardware.
- Document what was tested on which OS and browser, and what was not.

## Acceptance criteria

- A person with the hardware can follow the Windows or macOS README from a fresh machine to a successful registration.
- The top-level README links to the per-OS pages and no longer says "Linux only".

Depends on: the OS-specific issues above (write the docs as each one lands).
