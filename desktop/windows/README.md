# Windows

From a fresh Windows 10/11 PC to a registration in the browser. The top-level `README.md` explains the hardware and
wiring (Part A steps 1–2); this page replaces its Linux-specific steps.

## Status

| Part | Status |
|---|---|
| Serial link (COM ports, `kernel32` through `ctypes`), token detection (Espressif VID `303A` first, Bluetooth COM ports skipped) | implemented; host tests with a fake registry and a fake `kernel32` pass in CI; **not tested with the token** |
| `fpctl.py` (status, enroll, test, delete), also while the bridge runs | implemented; **not tested with the token** |
| Virtual FIDO device | prototype: VHF driver + `pico-vhid.exe` in [vhid/](vhid/README.md), builds in CI, **never installed or run** |
| Helper scripts | `setup-token.ps1`, `check-token.ps1`, `start-bridge.ps1`; run in CI against a fake token |
| Browser registration (Edge, Chrome) | **not tested** |

Nothing on this page was run with the real token yet. Steps marked *(to verify)* are expected behaviour, not observed.

| File | Purpose |
|---|---|
| `setup-token.ps1` | interactive: fingers enrolled, enrol/test/delete; initialise keys, FIDO reset and start the bridge (administrator) |
| `check-token.ps1` | read-only status; exit code 0 = ready |
| `start-bridge.ps1` | runs `..\common\ctaphid_serial_bridge.py`, which starts `vhid\pico-vhid.exe` (administrator) |
| `common.ps1` | helpers shared by the three scripts (dot-sourced) |
| `vhid\` | the virtual HID driver and helper, [vhid/README.md](vhid/README.md) |
| `virtual-hid.md` | the options for a virtual FIDO device on Windows and the decision |

Run a script with `powershell -ExecutionPolicy Bypass -File desktop\windows\check-token.ps1` (or `pwsh -File ...`).

## From a fresh PC

1. **Python 3** from https://www.python.org/downloads/windows/ (tick "Add python.exe to PATH"; the scripts use the `py`
   launcher when present). No Python packages are needed.
2. **ESP-IDF v5.5.** Espressif's "ESP-IDF Tools Installer" for Windows (Get Started guide for ESP32-C6, Windows). Open
   the "ESP-IDF 5.5 PowerShell" it creates, go to the repository and build exactly as in the top-level README step 3.
3. **Flash** through the board's **UART** port, as on Linux (top-level README step 4):
   `idf.py -p COM4 flash monitor`. The UART port is the board's USB-to-UART chip; Windows normally installs its driver
   by itself, otherwise install the chip vendor's driver (Silicon Labs CP210x or WCH CH343, depending on the board
   revision). Device Manager, "Ports (COM & LPT)", shows the COM number. No `dialout` group or `sudo` on Windows.
4. **Token link.** Plug the **native USB** port. Windows binds the C6's USB-Serial/JTAG to the built-in `usbser.sys`
   driver: "USB Serial Device (COMn)", hardware ID `USB\VID_303A&PID_1001&MI_00` *(to verify)*. No driver to install;
   the JTAG interface needs one only for debugging. You do not need to know the COM number: the tools find the token by
   asking every COM port (`py -3 ctaphid_serial_bridge.py --list`).
5. **Enrol a fingerprint:** `desktop\windows\setup-token.ps1`, or `cd desktop\common; py -3 fpctl.py enroll`.
6. **Virtual FIDO device** (once, administrator): build or download the driver and helper and install them,
   [vhid/README.md](vhid/README.md). This needs test-signing mode (a reboot, Secure Boot off).
7. **Start the bridge** from an **administrator** PowerShell: `desktop\windows\start-bridge.ps1`. Leave it open.
8. **Browser.** Nothing to set up: Edge, Chrome and Firefox reach security keys through Windows' WebAuthn service, so
   they need no permissions. Open https://www.token2.com/tools/fido2-demo, register; Windows' own dialog asks for the
   PIN (set one if asked, as on Linux), and the bridge window prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<`.

## Daily use

1. Plug the token into the native USB port, wait about 3 seconds.
2. Administrator PowerShell: `desktop\windows\start-bridge.ps1`, leave it open.
3. Use the browser; touch the sensor when the bridge says so.

`fpctl.py` works while the bridge runs. Unplugging is fine: the bridge reconnects.

## Checking the serial side with the hardware

Detection and unplug/replug can be checked without the virtual device. From `desktop\common`:

```powershell
py -3 ctaphid_serial_bridge.py --list          # the token's COM port, marked "-> token"
py -3 fpctl.py status                          # "token on COMn", then "sensor OK, N fingerprint(s) enrolled"
py -3 ctaphid_serial_bridge.py --no-hid -v     # "token on COMn"; unplug: "serial link lost"; replug: "token on COMn" again
```

Watch the token's UART log meanwhile (`idf.py -p COMx monitor` on the UART port): opening the native port must not
reboot the chip. `WindowsSerial` leaves DTR and RTS de-asserted for that reason (the USB-Serial/JTAG resets the chip when
RTS is asserted while DTR is not). Ports from COM10 up are opened as `\\.\COM10`.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `no token found` | wrong USB port, or another program has the COM port | native USB port; close serial monitors / `idf.py monitor` on that port |
| `cannot open COMn: [WinError 5] Access is denied` | the port is open in another program | close it |
| no "USB Serial Device" in Device Manager | charge-only cable, or only the UART port is plugged | data cable on the native USB port |
| `the Windows virtual HID helper is not installed` | `vhid\pico-vhid.exe` missing | [vhid/README.md](vhid/README.md) |
| `access denied: run the bridge as administrator` (from `pico-vhid`) | normal PowerShell, or a second bridge | administrator PowerShell, one bridge |
| `the pico_vhf driver is not installed` | driver missing or not started | `vhid\install.ps1`; check Device Manager; is test-signing on? |
| browser waits forever, the bridge shows no `host->token` lines with `-v` | Windows does not see the virtual device | Device Manager, Human Interface Devices: is a FIDO device present while the bridge runs? |
| `fido2-token -L` lists only `windows://hello` | not an administrator prompt | run it as administrator |
| script refuses to run ("running scripts is disabled") | execution policy | `powershell -ExecutionPolicy Bypass -File ...` |
