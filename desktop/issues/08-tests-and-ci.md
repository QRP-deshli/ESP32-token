---
title: "Cross-platform tests and CI (Linux, Windows, macOS)"
labels: desktop,ci,enhancement
---
## Why

The host tests only run on Linux, and the Python tests use Linux-only helpers. There is no CI.

## Where to look

- `desktop/common/tests/test_bridge_e2e.py`: a fake token on a `pty` and a fake `/dev/uhid` made from a
  `SOCK_SEQPACKET` socketpair (top of the file). `pty` and `SOCK_SEQPACKET` are not available on Windows.
- `desktop/common/tests/test_fpctl.py`: also uses `pty`.
- `desktop/common/tests/test_fp_core.c`, `test_serial_proto.c`: plain C tests of firmware code (`pico-keys-sdk/src/fingerprint/`
  and `pico-keys-sdk/src/usb/serial/`); build commands are in the top-level `README.md` ("Host tests").

## What to do

- Make the fake token and the fake virtual-HID pluggable (builds on issue 01) so the same tests run on all three OS; keep
  the pty-based version for Linux/macOS if it is the simplest.
- Add a GitHub Actions workflow with an OS matrix (ubuntu, windows, macos) that runs the Python tests and the two C tests
  (gcc/clang; decide how to build the C tests on Windows, for example MSYS2/clang, or skip them there).
- Add a basic script check (for example `shellcheck` on `desktop/linux/*.sh` and `desktop/mac/*.sh`).

## Acceptance criteria

- The workflow is green on all three OS for the existing tests.
- A new Windows- or macOS-specific backend can be covered by a test that does not need hardware.
