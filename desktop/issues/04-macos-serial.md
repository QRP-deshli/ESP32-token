---
title: "macOS: serial port access and token detection"
labels: desktop,macos,enhancement
---
## Why

`candidate_ports()` only knows Linux names (`/dev/serial/by-id/*`, `/dev/ttyACM*`, `/dev/ttyUSB*`). On macOS the token
appears as `/dev/cu.usbmodem*` (and a matching `/dev/tty.usbmodem*`).

## Where to look

`desktop/common/ctaphid_serial_bridge.py`: `candidate_ports` (L159), `open_serial` (L99), `BAUDS`, `probe`,
`Bridge.pick_port`. `termios` exists on macOS, but check every flag and baud constant used. `desktop/common/fpctl.py`:
`open_token`.

## What to do

- Add macOS port candidates (prefer `/dev/cu.*`; `/dev/tty.*` can block on carrier detect) and keep the PING/PONG `probe`
  as the final test.
- Verify `open_serial` behaves on macOS (raw mode, non-blocking reads, `CLOCAL`) and that opening the port does not reset
  the chip (see the DTR/RTS note in issue 02).
- Make sure nothing assumes ModemManager or udev. Check whether any macOS service grabs the port.
- Handle unplug/replug.

## Acceptance criteria

- `python3 fpctl.py status` works on macOS (Apple silicon and, if possible, Intel) with no hard-coded port.
- The bridge logs `token on /dev/cu.usbmodemXXXX` and recovers after replug.

Depends on: 01.
