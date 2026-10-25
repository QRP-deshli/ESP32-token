---
title: "(optional) Let fpctl work while the bridge is running"
labels: desktop,enhancement
---
## Why

`fpctl.py` and the bridge both need the token's serial port, so today the bridge must be stopped to enrol, delete or test
fingers (all the helper scripts stop and restart it). If the bridge owned the port and offered a small local control
channel, `fpctl` could work through it, on every OS, and the scripts would be simpler.

## Where to look

`desktop/common/ctaphid_serial_bridge.py`: `Bridge.on_serial_readable` (frames from the token; the fingerprint admin
frames use `T_FP = 0x30`, defined in `fpctl.py`), `Bridge.on_uhid_event`. `desktop/common/fpctl.py`: `request()`, `open_token()`.
Firmware side, for reference only: `pico-keys-sdk/src/fingerprint/` and `pico-keys-sdk/src/usb/serial/serial_proto.h`.

## What to do

- Add a local control endpoint to the bridge (a localhost TCP port, a Unix socket, or a Windows named pipe) that forwards
  `T_FP` frames to the token and returns the replies.
- Make `fpctl` use the endpoint if a bridge is running, and the serial port directly otherwise.
- Keep the user-facing commands and output unchanged.

## Acceptance criteria

- `fpctl status` and `fpctl enroll` work while the bridge is running, on Linux first.
- No change to CTAPHID traffic while an admin request is in progress, or a clear error if the two collide.
