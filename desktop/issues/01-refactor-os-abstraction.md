---
title: "Refactor: separate OS-specific code from the protocol code in desktop/common"
labels: desktop,enhancement
---
## Why

`desktop/common/ctaphid_serial_bridge.py` mixes protocol code (portable) with Linux-only code, and `fpctl.py` imports the
bridge module and reuses its Linux serial helpers. Windows and macOS support is much easier if the OS-specific parts sit
behind two small interfaces.

## Where to look (line numbers as of this commit)

`desktop/common/ctaphid_serial_bridge.py`
- Portable: `crc16`, `encode`, `Decoder` (L38-L96), the frame constants.
- Serial, POSIX-only: `import termios` (L25), `open_serial` (L99, `os.open` + `termios`), `write_all` (L119, `select` on a
  file descriptor), `probe` (L132), `candidate_ports` (L159, `/dev/serial/by-id`, `/dev/ttyACM*`, `/dev/ttyUSB*`).
- Virtual HID, Linux-only: `uhid_create2`, `uhid_input`, `uhid_reply` and the `UHID_*` structs (L168-L220),
  `Bridge.on_uhid_event`. `FIDO_REPORT_DESC` (the standard FIDO HID report descriptor) is reusable on any OS.
- Main loop: `Bridge.run` (L334) is a `select.select` loop on two file descriptors, which does not work on Windows.

`desktop/common/fpctl.py`: `request()` and `open_token()` use `os.read`, `select` and the bridge's `open_serial`.

## What to do

- Introduce two small interfaces, for example `SerialLink` (open by name, read with timeout, write, close, list ports) and
  `VirtualHid` (create the device with `FIDO_REPORT_DESC`, deliver output reports from the OS to the bridge, send input
  reports to the OS, destroy).
- Keep the Linux implementations as the first backends (`termios`/`uhid`), move the frame code to its own module.
- Make `Bridge` and `fpctl` use the interfaces; no `termios`, `select` on fds, `uhid` or `/dev` strings outside the Linux
  backends.
- Decide whether to depend on **pyserial** (simple, cross-platform, adds a dependency; the project is stdlib-only today)
  or keep stdlib-only with `ctypes` backends. Write the decision in the PR.

## Acceptance criteria

- No change in Linux behaviour; all host tests in `desktop/common/tests/` still pass; Linux scripts still work.
- The protocol module imports no OS-specific module.
- A backend can be added without editing `Bridge` or `fpctl`.
