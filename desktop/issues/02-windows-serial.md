---
title: "Windows: serial port access and token detection"
labels: desktop,windows,enhancement
---
## Why

The bridge and `fpctl` open `/dev/ttyACM0`-style paths with `termios`. On Windows the token is a COM port.

## Where to look

`desktop/common/ctaphid_serial_bridge.py`: `open_serial`, `write_all`, `probe`, `candidate_ports`, `Bridge.pick_port`,
`Bridge.connect_serial`, `Bridge.drop_serial`. `desktop/common/fpctl.py`: `open_token`, `request`.

## What to do

- Implement a Windows `SerialLink` backend (see issue 01): either pyserial, or `ctypes` + `kernel32` (`CreateFileW`,
  `SetCommState`, `SetCommTimeouts`, overlapped I/O or a reader thread, since `select` does not work on handles). Remember
  the `\\.\COM10` form for ports above COM9.
- Port detection: list COM ports and prefer Espressif's USB VID `0x303A` (the ESP32 USB-Serial/JTAG normally shows up as
  `303A:1001`; please verify on the hardware), then confirm with the existing `probe` (PING/PONG), exactly as Linux does.
- Check what the Windows USB driver situation is for the C6's USB-Serial/JTAG (built-in `usbser` or an Espressif driver)
  and document it.
- Check whether opening the port toggles DTR/RTS and resets the chip (some ESP32 tools use DTR/RTS for reset/boot
  modes). The Linux code does not touch DTR/RTS; Windows may assert them on open. The token must not reboot when the bridge
  connects.
- Handle the token being unplugged and replugged (the Linux loop retries every second, `Bridge.run`).

## Acceptance criteria

- `python fpctl.py status` prints `sensor OK, N fingerprint(s) enrolled` on Windows, with the token plugged in and no
  hard-coded COM port.
- The bridge finds the token and logs `token on COMn`; unplug/replug recovers.
- Documented driver requirements.

Depends on: 01 (can be started in parallel if the interface is agreed).
