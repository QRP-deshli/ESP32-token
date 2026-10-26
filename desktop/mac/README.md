# macOS

> **Conceptual only, not pursued for now.** A virtual HID device on macOS needs Apple's restricted entitlement
> `com.apple.developer.hid.virtual.device`, which comes only with a paid Apple Developer Program membership and Apple's
> approval of the capability (see [virtual-hid.md](virtual-hid.md)). Without it the bridge cannot expose the token to
> browsers, so the macOS path cannot be verified end to end. The code and scripts stay in the repository as a concept
> for whoever has such an account; use the token on Linux or Windows.

From a fresh Mac to a registration in the browser. The top-level `README.md` explains the hardware and wiring (Part A
steps 1–2); this page replaces its Linux-specific steps.

## Status

| Part | Status |
|---|---|
| Serial link, token detection (`/dev/cu.usbmodem*`) | **tested with the token** (macOS 27, Apple silicon): `--list` finds `/dev/cu.usbmodem2101 -> token`, `--no-hid` connects; unplug/replug not tried |
| `fpctl.py status` | **tested with the token**: `sensor OK, 1 fingerprint(s) enrolled`; enroll/test/delete not tried on macOS |
| Virtual FIDO device (`vhid/pico-vhid`) | implemented and builds; runs only with Apple's HID entitlement, see [virtual-hid.md](virtual-hid.md); **never created a device** (no Apple Developer account) |
| Helper scripts | `setup-token.sh`, `check-token.sh`, `start-bridge.sh` (bash 3.2), run in CI against a fake token |
| Browser registration (Chrome, Safari) | **not tested**, blocked by the virtual device |

Only the serial side was run with the real token. Steps marked *(to verify)* are expected behaviour, not observed.

| File | Purpose |
|---|---|
| `setup-token.sh` | interactive: fingers enrolled, enrol/test/delete, initialise keys, new token identity (FIDO reset), start bridge |
| `check-token.sh` | read-only status (also runs `vhid/pico-vhid --check`); exit code 0 = ready |
| `start-bridge.sh` | runs `../common/ctaphid_serial_bridge.py`, which starts `vhid/pico-vhid` |
| `common.sh` | helpers shared by the three scripts (sourced) |
| `vhid/` | the virtual HID helper (Swift), `build.sh`, entitlements file |
| `virtual-hid.md` | options, decision, the entitlement and how to sign |

## From a fresh Mac

1. **Tools.** Xcode command line tools (`xcode-select --install`), Python 3 (the system `python3` or
   `brew install python`; standard library only, no `pyserial`), and for the command-line FIDO checks `brew install libfido2` (`fido2-token`, `fido2-cred`).
2. **ESP-IDF v5.5.** Espressif's Get Started guide for ESP32-C6, "Linux and macOS": `brew install cmake ninja dfu-util`,
   clone ESP-IDF v5.5, `./install.sh esp32c6`, `. ./export.sh`. Build exactly as in the top-level README step 3.
3. **Flash** through the board's **UART** port, as on Linux (top-level README step 4):
   `idf.py -p /dev/cu.usbserial-XXXX flash monitor` (`ls /dev/cu.*` shows the name; boards with a WCH chip appear as
   `/dev/cu.wchusbserial*` and may need WCH's driver on older macOS). No `dialout` group, no `sudo`.
4. **Token link.** Plug the **native USB** port. macOS' built-in CDC-ACM driver makes it `/dev/cu.usbmodemXXXX` *(to
   verify the exact name)*. Nothing to install, no permissions to grant; there is no ModemManager on macOS. The tools
   find the port themselves (`python3 desktop/common/ctaphid_serial_bridge.py --list`). Always `/dev/cu.*`, never
   `/dev/tty.*` (that one waits for carrier detect).
5. **Enrol a fingerprint:** `desktop/mac/setup-token.sh`, or `cd desktop/common && python3 fpctl.py enroll`.
6. **Virtual FIDO device** (once): get the HID entitlement and a provisioning profile, then
   `desktop/mac/vhid/build.sh "Apple Development: you (TEAMID)" profile.provisionprofile` and check with
   `desktop/mac/vhid/pico-vhid --check`. Details and the alternatives: [virtual-hid.md](virtual-hid.md).
7. **Start the bridge:** `desktop/mac/start-bridge.sh` (no `sudo`). Leave it open.
8. **Browser.** Nothing to set up: Chrome and Firefox open HID security keys directly, Safari through the system. Open
   https://www.token2.com/tools/fido2-demo, register, set a PIN if asked (as on Linux), and touch the sensor when the
   bridge prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<`.

## Daily use

1. Plug the token into the native USB port, wait about 3 seconds.
2. `desktop/mac/start-bridge.sh`, leave it open.
3. Use the browser; touch the sensor when the bridge says so.

`fpctl.py` works while the bridge runs. Unplugging is fine: the bridge reconnects.

## Checking the serial side with the hardware

Detection and unplug/replug can be checked without the virtual device. From `desktop/common`:

```sh
python3 ctaphid_serial_bridge.py --list         # /dev/cu.usbmodemXXXX -> token
python3 fpctl.py status                         # "token on /dev/cu.usbmodemXXXX", "sensor OK, N fingerprint(s) enrolled"
python3 ctaphid_serial_bridge.py --no-hid -v    # unplug: "serial link lost"; replug: "token on /dev/cu.usbmodemXXXX" again
```

Watch the token's UART log meanwhile: opening the native port must not reboot the chip. The tools open the port
exclusively (`TIOCEXCL` and a lock), so a second program gets "in use". No macOS service was found that opens
`/dev/cu.usbmodem*` by itself; confirm with `lsof /dev/cu.usbmodem*`.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `no token found` | wrong USB port | native USB port; `ls /dev/cu.usbmodem*` |
| `… is in use` or `Resource busy` | another program (serial monitor, `idf.py monitor`, a second bridge) has the port | close it; `lsof /dev/cu.usbmodem*` shows which |
| `the macOS virtual HID helper is not built` | `vhid/pico-vhid` missing | `desktop/mac/vhid/build.sh` |
| `pico-vhid: cannot create the virtual HID device` | helper built without the entitlement | [virtual-hid.md](virtual-hid.md), "Getting the entitlement" |
| the bridge stops with `virtual HID helper exited (status -9)` | macOS killed a binary that claims the entitlement without a provisioning profile | build the app bundle with the profile ([virtual-hid.md](virtual-hid.md)) |
| `check-token.sh` says the bridge is not running although it is | Python started under an unusual name | `ps ax \| grep ctaphid` shows the command line; please report it |
| browser waits forever, the bridge shows no `host->token` lines with `-v` | the virtual device is not seen | `pico-vhid --check`; `ioreg -p IOService -l \| grep -i 619b` while the bridge runs |
