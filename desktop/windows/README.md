# Windows

| Part | Status |
|---|---|
| Serial link (COM ports, `kernel32` through `ctypes`), token detection (Espressif VID `303A` first) | implemented, host tests of the detection logic pass; **not tested on Windows with the token** |
| `fpctl.py` (status, enroll, test, delete) | implemented; **not tested on Windows with the token** |
| Virtual FIDO device | **not available**: needs a helper, see [virtual-hid.md](virtual-hid.md) |
| Helper scripts | `setup-token.ps1`, `check-token.ps1`, `start-bridge.ps1`; **not run on Windows yet** (checked in CI by the PowerShell parser) |
| Browser registration | **not possible yet** (no virtual device) |

| File | Purpose |
|---|---|
| `setup-token.ps1` | interactive: fingers enrolled, enrol/test/delete; initialise keys, FIDO reset and the bridge once a helper exists |
| `check-token.ps1` | read-only status; exit code 0 = ready |
| `start-bridge.ps1` | runs `..\common\ctaphid_serial_bridge.py` with the helper from `PICO_VHID_HELPER` |
| `common.ps1` | helpers shared by the three scripts (dot-sourced) |

Run a script with `powershell -ExecutionPolicy Bypass -File desktop\windows\check-token.ps1` (or `pwsh -File ...`).

## From a fresh PC

1. **Python 3** from https://www.python.org/downloads/windows/ (tick "Add python.exe to PATH"; the `py` launcher is
   used when present). No extra Python packages: everything is standard library.
2. **ESP-IDF v5.5, build and flash.** Use Espressif's Windows installer (ESP-IDF Tools Installer, "Get Started" for
   Windows), open the "ESP-IDF 5.5 PowerShell", then build as in the top-level README step 3. Flash through the board's
   **native USB** port: `idf.py -p COM5 flash` (the COM number is in Device Manager, "Ports (COM & LPT)").
3. **Driver.** Windows 10/11 bind the C6's USB-Serial/JTAG serial interface to the built-in `usbser.sys` driver, so it
   appears as "USB Serial Device (COMn)". The JTAG interface needs a driver only for debugging (the ESP-IDF installer
   offers it). To verify on the hardware: Device Manager shows `USB\VID_303A&PID_1001&MI_00`.
4. **Enrol a fingerprint.** `setup-token.ps1`, or `cd desktop\common; py -3 fpctl.py enroll`.
5. **Virtual device and browsers**: not possible yet, see [virtual-hid.md](virtual-hid.md).

## Notes for whoever tests this with the hardware

- **DTR/RTS.** The ESP32 USB-Serial/JTAG resets the chip when RTS is asserted while DTR is not (that is how esptool
  resets it). `WindowsSerial` sets `DTR_CONTROL_DISABLE` and `RTS_CONTROL_DISABLE`, so opening the port should not reset
  the token. Check that the token does not reboot when `fpctl.py status` runs (the ESP32 monitor would show the boot log).
- **Unplug/replug.** A read on a removed COM port fails; the bridge then logs `serial link lost` and probes again every
  second, like on Linux.
- **COM10 and above** are opened as `\\.\COM10`; `--port COM12` works as is.
- `fido2-token` for Windows (libfido2 release zip) lists HID keys only from an administrator prompt.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `no token found` | wrong USB port, or another program has the COM port | native USB port; close serial monitors / `idf.py monitor`; stop the bridge |
| `cannot open COMn: [WinError 5] Access is denied` | the port is open in another program | close it |
| no COM port in Device Manager | charge-only cable, or the UART port was used | data cable on the native USB port |
| `this OS has no built-in virtual HID backend` | no helper | expected for now, see [virtual-hid.md](virtual-hid.md) |
| script refuses to run ("running scripts is disabled") | execution policy | `powershell -ExecutionPolicy Bypass -File ...` |
