---
title: "Helper scripts for Windows (PowerShell) and macOS (zsh/bash)"
labels: desktop,windows,macos,enhancement
---
## Why

`desktop/linux/` has three scripts that make the token easy to use. Windows and macOS need equivalents in their own
folders.

## Where to look

`desktop/linux/setup-token.sh`, `check-token.sh`, `start-bridge.sh`, `common.sh`. Read `common.sh` first: it contains the
OS-specific actions.

| Linux action (in `common.sh`) | Function | Needs an equivalent |
|---|---|---|
| `sudo systemctl stop ModemManager` | `prepare_system` | probably nothing on Windows/macOS, but check |
| `sudo modprobe uhid` | `prepare_system` | the virtual-HID prerequisites from issues 03 / 05 |
| `pgrep` / `pkill` of the bridge | `bridge_running`, `stop_bridge` | `Get-Process`/`Stop-Process` on Windows; `pgrep`/`pkill` exist on macOS |
| `sudo` for the bridge | `start_bridge_bg`, `start-bridge.sh` | elevation on Windows if the virtual-HID option needs it |
| `fido2-token -L` to find the virtual device | `find_hid_device` | `fido2-token` for Windows/macOS (libfido2 tools), or another check |
| `fpctl.py status` parsing | `refresh_state`, `print_state` | same Python, run as `python`/`python3` |
| udev rule | `70-pico-fido2.rules` | not needed, or the OS-specific permission setup |

## What to do

- Windows: `setup-token.ps1`, `check-token.ps1`, `start-bridge.ps1` in `desktop/windows/`.
- macOS: `setup-token.sh`, `check-token.sh`, `start-bridge.sh` in `desktop/mac/` (macOS ships bash 3.2: no associative
  arrays, no `${var,,}`, careful with empty arrays under `set -u`).
- Same menu and the same wording as the Linux scripts; keep the same exit codes (`check-token`: 0 ready, 1 not ready).
- Same safety rules: typing `RESET` for a FIDO reset, never touch the token's keys silently.

## Acceptance criteria

- Each script runs on its OS against real hardware and does what its Linux twin does (setup menu, status, start bridge).
- A reset test: the reset must be started within 10 seconds of the token's power-up (see `reset_flow` in
  `setup-token.sh`); check that the flow on your OS still meets that.

Depends on: 02 and 03 (Windows), 04 and 05 (macOS).
