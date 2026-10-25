# macOS

| Part | Status |
|---|---|
| Serial link, token detection (`/dev/cu.usbmodem*`) | implemented, host tests pass on macOS; **not tested with the token** |
| `fpctl.py` (status, enroll, test, delete) | implemented, host tests pass; **not tested with the token** |
| Virtual FIDO device (`vhid/pico-vhid`) | implemented and builds; needs the HID entitlement to run, see [virtual-hid.md](virtual-hid.md) |
| Helper scripts | `setup-token.sh`, `check-token.sh`, `start-bridge.sh` (bash 3.2), checked against a fake token |
| Browser registration | **not tested** (needs the entitlement and the hardware) |

| File | Purpose |
|---|---|
| `setup-token.sh` | interactive: fingers enrolled, enrol/test/delete, initialise keys, new token identity (FIDO reset), start bridge |
| `check-token.sh` | read-only status; exit code 0 = ready |
| `start-bridge.sh` | runs `../common/ctaphid_serial_bridge.py`, which starts `vhid/pico-vhid` |
| `common.sh` | helpers shared by the three scripts (sourced) |
| `vhid/` | the virtual HID helper (Swift), `build.sh`, entitlements file |

## From a fresh Mac

1. **Tools.** Xcode command line tools (`xcode-select --install`), Python 3 (the system `python3`, or `brew install
   python`), and for the FIDO checks `brew install libfido2` (gives `fido2-token`, `fido2-cred`, `fido2-assert`).
2. **ESP-IDF v5.5, build and flash.** Follow Espressif's macOS guide (Get Started, "Installation of ESP-IDF on Linux and
   macOS": `brew install cmake ninja dfu-util`, then `./install.sh esp32c6` and `. ./export.sh`). Build exactly as in the
   top-level README step 3. To flash, plug the board's **native USB** port (the one labelled USB, not UART) and use the
   port macOS created: `idf.py -p /dev/cu.usbmodem101 flash` (`ls /dev/cu.usbmodem*` shows the name).
3. **Driver and permissions.** None: macOS has a built-in CDC-ACM driver for the C6's USB-Serial/JTAG, and the port is
   accessible to the logged-in user without `sudo`. Use `/dev/cu.*`, not `/dev/tty.*` (the latter waits for carrier
   detect). There is no ModemManager on macOS.
4. **Enrol a fingerprint.** `desktop/mac/setup-token.sh`, or by hand: `cd desktop/common && python3 fpctl.py enroll`.
5. **Virtual device.** Build and sign the helper with the entitlement ([virtual-hid.md](virtual-hid.md)):
   `desktop/mac/vhid/build.sh "Apple Development: you (ID)"`.
6. **Daily use.** `desktop/mac/start-bridge.sh`, leave it open, register on https://www.token2.com/tools/fido2-demo in
   Chrome. The bridge prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<` when the token waits for a finger.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `no token found` | wrong USB port, or the bridge holds the port | use the native USB port; stop the bridge; `ls /dev/cu.usbmodem*` |
| `cannot open /dev/cu.usbmodem…: Resource busy` | another program (serial monitor, `idf.py monitor`, the bridge) has the port | close it |
| `the macOS virtual HID helper is not built` | `vhid/pico-vhid` missing | `desktop/mac/vhid/build.sh` |
| `pico-vhid: cannot create the virtual HID device` | helper built without the entitlement | sign it with the entitlement, [virtual-hid.md](virtual-hid.md) |
| the bridge stops with `virtual HID helper exited (status -9)` | macOS killed a binary that claims the entitlement without a valid profile | see [virtual-hid.md](virtual-hid.md), "Getting the entitlement" |
| `check-token.sh` says the bridge is not running although it is | Python started under an unusual name | report it; `ps ax | grep ctaphid` shows the command line |

## Not tested

Everything with the real token: serial open (raw mode, DTR/RTS at open must not reset the chip), unplug/replug, the
10-second reset window in `setup-token.sh`, Chrome/Safari registration, Intel Macs.
