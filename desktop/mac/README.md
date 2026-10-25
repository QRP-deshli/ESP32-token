# macOS

| Part | Status |
|---|---|
| Serial link, token detection (`/dev/cu.usbmodem*`), exclusive open, unplug/replug | implemented, host tests on a pty pass on macOS; **not tested with the token** |
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
5. **Virtual device.** Get the HID entitlement and a provisioning profile, then build the signed helper app
   ([virtual-hid.md](virtual-hid.md)): `desktop/mac/vhid/build.sh "Apple Development: you (ID)" profile.provisionprofile`,
   and check it with `desktop/mac/vhid/pico-vhid --check`.
6. **Daily use.** `desktop/mac/start-bridge.sh`, leave it open, register on https://www.token2.com/tools/fido2-demo in
   Chrome. The bridge prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<` when the token waits for a finger.

## Checking the serial side with the hardware

The acceptance checks of the macOS serial issue; they need the token and were not run yet. From `desktop/common`:

```sh
python3 ctaphid_serial_bridge.py --list         # /dev/cu.usbmodemXXXX -> token
python3 fpctl.py status                         # "token on /dev/cu.usbmodemXXXX", "sensor OK, N fingerprint(s) enrolled"
python3 ctaphid_serial_bridge.py --no-hid -v    # unplug: "serial link lost"; replug: "token on /dev/cu.usbmodemXXXX" again
```

While the bridge runs, `python3 fpctl.py status` must say the port is in use (the bridge holds it exclusively). Watch the
token's UART log on the other USB port: opening the native port must not reboot the chip. macOS has no ModemManager; no
system service was found that opens `/dev/cu.usbmodem*` by itself (to confirm with `lsof /dev/cu.usbmodem*`).

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `no token found` | wrong USB port, or the bridge holds the port | use the native USB port; stop the bridge; `ls /dev/cu.usbmodem*` |
| `cannot open /dev/cu.usbmodem…: Resource busy` or `… is in use` | another program (serial monitor, `idf.py monitor`, the bridge) has the port | close it; `lsof /dev/cu.usbmodem*` shows which |
| `the macOS virtual HID helper is not built` | `vhid/pico-vhid` missing | `desktop/mac/vhid/build.sh` |
| `pico-vhid: cannot create the virtual HID device` | helper built without the entitlement | sign it with the entitlement, [virtual-hid.md](virtual-hid.md) |
| the bridge stops with `virtual HID helper exited (status -9)` | macOS killed a binary that claims the entitlement without a valid profile | see [virtual-hid.md](virtual-hid.md), "Getting the entitlement" |
| `check-token.sh` says the bridge is not running although it is | Python started under an unusual name | report it; `ps ax | grep ctaphid` shows the command line |

## Not tested

Everything with the real token: serial open (raw mode, DTR/RTS at open must not reset the chip), unplug/replug, the
10-second reset window in `setup-token.sh`, Chrome/Safari registration, Intel Macs.
