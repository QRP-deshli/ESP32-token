# Pico FIDO2 on ESP32-C6 with a fingerprint gate

A FIDO2 / WebAuthn security key on an **ESP32-C6** that only works after a **fingerprint** the sensor knows.
It is a port of [pico-fido2](https://github.com/polhenarejos/pico-fido2) (see `NOTICE.md` and `CHANGES.md`).

```
Browser / libfido2  --HID--  serial bridge (PC)        --USB serial--  ESP32-C6 token  --UART--  fingerprint sensor
                              virtual FIDO HID device                  keys + signing           matches fingers itself
                              (Linux uhid, Windows VHF
                               driver; macOS: concept)
```

The ESP32-C6 has no USB device controller, so it cannot be a USB HID key by itself. The firmware talks CTAPHID over
the C6's native USB port (a serial port: `/dev/ttyACM0` on Linux, `/dev/cu.usbmodem…` on macOS, `COMn` on Windows) and
a small Python program on the PC (`desktop/`) turns that into a virtual USB HID FIDO device. **The bridge must run on
every PC where you use the token.** Linux and Windows work and were tested with the hardware; macOS is a concept only
(it needs an Apple entitlement), see [Operating systems](#operating-systems). This manual covers Linux and Windows:
where the two differ, each step shows both. The Windows driver installation has its own guide,
[desktop/windows/README.md](desktop/windows/README.md).

## What is stored where

| Thing | Where | Survives a normal re-flash? |
|---|---|---|
| Two secret keys (master key encryption keys) | ESP32 eFuse KEY3/KEY4, burned **once** on first boot | yes, permanent |
| Device key, attestation certificate, counter, PIN, registered credentials | `part0` flash partition, created on first boot only if missing | yes |
| Fingerprints | inside the fingerprint sensor module (the ESP32 never sees them) | yes |

Re-flashing with `idf.py flash` writes the bootloader, partition table and app only, so nothing above changes.
Keys and credentials are lost by `idf.py erase-flash`, by a FIDO reset (`fido2-token -R`) or by editing `partitions.csv`.
Fingerprints are lost only by `fpctl.py delete` / `delete-all`.

## Status

Tested on a real ESP32-C6-DevKitC-1 with a Waveshare-style UART capacitive fingerprint module (pins VIN, GND, TX,
RX, IRQ, EN), ESP-IDF v5.5, on Ubuntu (Brave) and on Windows 10/11:

- build, flash, first boot, fingerprint enrolment, finger test (`fpctl.py`)
- `fido2-token -I`, registration and login with `fido2-cred` / `fido2-assert` (both ask for the finger)
- registration and login on the [Token2 FIDO2 demo](https://www.token2.com/tools/fido2-demo) in a browser, with a PIN
  set (Brave on Ubuntu; on Windows through the test-signed VHF driver)

**Not tested:** other websites, other fingerprint module models, macOS beyond the serial side, and a stranger's finger being refused in the
browser (the firmware refuses on a failed match; check it yourself), resident keys/passkeys beyond the demo.

**Does not work:** Firefox and Chrome/Chromium on Ubuntu installed as a snap or flatpak (Ubuntu's default Firefox is a
snap). Their sandbox does not let them open the bridge's `/dev/hidraw*` device. Use a browser from a `.deb` package
(for example Brave).

### Operating systems

| | Linux | macOS | Windows |
|---|---|---|---|
| Status | **works** | **concept only** | **works** |
| Token detection, `fpctl.py` | tested with the token | tested with the token (`--list`, `fpctl.py status`) | tested with the token |
| Virtual FIDO device | `/dev/uhid`, tested | `desktop/mac/vhid` helper, needs Apple's HID entitlement (paid developer account), never created a device | test-signed VHF driver `desktop/windows/vhid`, tested |
| Browser registration | tested (Brave) | not possible without the virtual device | tested |
| Helper scripts | `desktop/linux/` (bash) | `desktop/mac/` (bash 3.2) | `desktop/windows/` (`.cmd`) |
| Manual | this README | [desktop/mac/README.md](desktop/mac/README.md) | this README + [desktop/windows/README.md](desktop/windows/README.md) (driver) |

All three run the host tests in CI against a fake token. macOS stays a concept until someone with an Apple Developer
account gets the entitlement ([desktop/mac/virtual-hid.md](desktop/mac/virtual-hid.md)).

What was tested where, with the real token:

| OS | Browser / tool | Result |
|---|---|---|
| Ubuntu | Brave (deb), `fido2-token`, `fido2-cred`, `fido2-assert` | registration and login with PIN and fingerprint work |
| Ubuntu | Firefox, Chrome (snap/flatpak) | does not work: the sandbox blocks access to `/dev/hidraw*` |
| Windows 10/11 | browser, `fido2-token` (administrator prompt) | driver installed, bridge creates `1d50:619b`, registration and login with PIN and fingerprint work |
| macOS 27 | `ctaphid_serial_bridge.py --list`, `fpctl.py status` | serial side works; no virtual device without Apple's HID entitlement |

**Not a hardened token.** Flash encryption and secure boot are off. Anyone holding the board can read its flash, and the
fingerprint is a gate (user presence), not part of the key material. See [Security notes](#security-notes).

---

# Part A: full setup in 10 steps

## 1. What you need

- **ESP32-C6-DevKitC-1** (two USB-C ports: *UART* for flashing and logs, *USB* = native, used as the token link), 4 MB flash or more.
- **Fingerprint module**, 3.3 V, UART, speaking the Waveshare *UART Fingerprint Sensor (D)* command set, plus jumper wires.
- **Two USB-C cables** (data, not charge-only).
- **A PC** with Python 3 (standard library only, no extra packages):
  - **Linux:** the `uhid` kernel module (present on Ubuntu).
  - **Windows 10/11 x64:** the virtual HID driver, built and installed once as in
    [desktop/windows/README.md](desktop/windows/README.md) sections 1–3 (MinGW, Visual Studio, SDK + WDK, test-signing
    mode, so Secure Boot must be off).
- **ESP-IDF v5.5** ([install guide](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32c6/get-started/)); Linux:
  `./install.sh esp32c6`; Windows: Espressif's "ESP-IDF Tools Installer".
- Internet during the first build (the ESP-IDF component manager downloads `zorxx/neopixel`).
- libfido2 tools for command-line tests: Linux `sudo apt install fido2-tools`; Windows: the libfido2 release zip,
  folder with `fido2-token.exe` on PATH.

## 2. Wiring

Use the labels printed on your module, not wire colours. TX and RX cross over.

| Module pin | ESP32-C6 pin |
|---|---|
| VIN | 3V3 |
| GND | GND |
| TX | GPIO11 |
| RX | GPIO10 |
| EN (or RST) | GPIO18 |
| IRQ / WAKE | not connected (the firmware does not use it) |

- **3.3 V only.** 5 V can damage the module or the ESP32.
- GPIO18 is driven high at boot and pulsed low to reset the module if it stops answering (it goes to sleep when idle;
  the log line `sensor silent, resetting it and retrying once` is normal). This assumes EN/RST is active-high, which worked
  with the tested module. If yours never answers, tie EN/RST to 3V3 and set `#define PICOKEY_FP_RST -1` in
  `pico-keys-sdk/src/fingerprint/fp_esp.c`.
- Pins can be changed with the defines at the top of that file. Avoid GPIO 4, 5, 8, 9, 12, 13, 15, 16, 17 (JTAG,
  strapping, USB, console).

## 3. Build

Linux (on Windows use the "ESP-IDF PowerShell" or "ESP-IDF CMD" shortcut instead of `export.sh`):

```sh
. ~/esp/esp-idf/export.sh
cd pico-fido2-esp32c6
idf.py fullclean
idf.py set-target esp32c6
idf.py build
```

`fullclean` matters if you built before: an old build folder remembers old options. The configure output must contain
`Fingerprint gate: enabled (user presence = fingerprint match)`. If not, stop and check this step again.
(`-DENABLE_FINGERPRINT=OFF` disables the gate for bench tests: then every register/login completes without any check.)

## 4. Flash

Plug a cable into the **UART** port.

```sh
# Linux
sudo usermod -aG dialout $USER        # once, then log out and in
idf.py -p /dev/ttyUSB0 flash monitor

# Windows (the UART chip shows as COMn in Device Manager, "Ports (COM & LPT)")
idf.py -p COM5 flash monitor
```

- The first boot **burns eFuse KEY3/KEY4: irreversible, once per chip.** Later flashes reuse them.
- The monitor should print `fingerprint: sensor ready, N enrolled`. `UART setup failed` means a driver/pin problem;
  `sensor silent` means wiring (step 2). Leave the monitor with Ctrl+].
- The port name may differ: Linux `ls /dev/ttyUSB* /dev/ttyACM*`; Windows: Device Manager.

## 5. Enrol a fingerprint

Plug the second cable into the **native USB** port (Linux `/dev/ttyACM0`, Windows "USB Serial Device (COMn)"). The
bridge must be **stopped** for this step.

Linux:

```sh
sudo systemctl stop ModemManager
sudo modprobe uhid
cd desktop/common
./ctaphid_serial_bridge.py --list     # should show /dev/ttyACM0 -> token
./fpctl.py status                     # "sensor OK, 0 fingerprint(s) enrolled"
./fpctl.py enroll                     # three touches, lifting in between
./fpctl.py test                       # "finger recognised (id 1)"
```

Windows (normal prompt, no administrator needed):

```
cd desktop\common
py -3 ctaphid_serial_bridge.py --list     the token's COM port, marked "-> token"
py -3 fpctl.py status
py -3 fpctl.py enroll
py -3 fpctl.py test
```

The first finger needs no authorisation; every later enrol/delete needs a touch with an already enrolled finger.
**Enrol a second finger as a backup.** The sensor holds a limited number of fingers.

Prefer a guided version? `desktop/linux/setup-token.sh` or `desktop\windows\setup-token.cmd` does these checks and the
enrolment interactively (see [Helper scripts](#helper-scripts)).

## 6. Start the bridge

Linux:

```sh
cd desktop/common
sudo ./ctaphid_serial_bridge.py -v    # leave this terminal open
```

(or `desktop/linux/start-bridge.sh`, which also stops ModemManager and loads `uhid`). In another terminal:

```sh
fido2-token -L                        # lists /dev/hidrawN
fido2-token -I /dev/hidrawN           # token info (add sudo if you have not done step 8)
```

Windows (administrator prompt, the driver must be installed):

```
desktop\windows\start-bridge.cmd -v      leave this window open
```

It must print `token on COMn` and `virtual FIDO device 1d50:619b created`. In another **administrator** prompt,
`fido2-token -L` lists a `\\?\hid#...` path (a normal prompt shows only `windows://hello`); use it with `fido2-token -I`.

The bridge prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<` whenever the token waits for your finger. The command-line
tools print nothing while they wait, so keep this window visible.

## 7. Register and log in from the command line

Replace `hidrawN`. Each step waits for your finger (about 15 seconds). If a PIN is set, the tools should ask for it.
The commands are for a Linux shell; on Windows run the same `fido2-cred` / `fido2-assert` calls in an administrator
prompt with the `\\?\hid#...` path (or in Git Bash/WSL for `openssl`), or simply test in the browser (step 8).

```sh
# register
echo "credential challenge" | openssl sha256 -binary | base64 > cred_param
echo "example.org" >> cred_param
echo "testuser" >> cred_param
head -c 32 /dev/urandom | base64 >> cred_param
fido2-cred -M -i cred_param /dev/hidrawN es256 | fido2-cred -V -o cred es256

# log in
echo "assertion challenge" | openssl sha256 -binary | base64 > assert_param
echo "example.org" >> assert_param
head -1 cred >> assert_param
tail -n +2 cred > pubkey
fido2-assert -G -i assert_param /dev/hidrawN | fido2-assert -V pubkey es256
```

No output and exit code 0 means success. To check the gate, repeat a command without touching the sensor (or with a
finger that is not enrolled): it must fail with `FIDO_ERR_OPERATION_DENIED` after the timeout.

## 8. Browsers

**Windows:** nothing to set up. Edge, Chrome and Firefox reach the key through Windows' WebAuthn service; the browser
itself runs as a normal user, only the bridge needs administrator rights. Continue with the numbered list below.

**Linux:** browsers run as your normal user and cannot open the root-only `/dev/hidrawN` the bridge creates. Install the udev
rule once, then restart the bridge (the device node is created when the bridge starts):

```sh
sudo cp desktop/linux/70-pico-fido2.rules /etc/udev/rules.d/
sudo udevadm control --reload
# restart the bridge, then:
ls -l /dev/hidraw*                    # the newest node should show crw-rw----+
```

Then open a WebAuthn site (for example the Token2 demo above), click register, and:

1. If the browser says **"PIN required: set up a new PIN"**, that is expected: the token supports a PIN but does not
   (yet) tell browsers that the fingerprint counts as user verification. Choose a PIN of at least 4 characters.
2. When the bridge prints the touch message, touch the sensor within 15 seconds.

Tested in Brave (deb package) on Linux and in a browser on Windows. To see why a Chromium browser fails, open
`brave://device-log` (`chrome://device-log`, `edge://device-log`) and reload it after clicking register.

## 9. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `fpctl status`: "sensor does not answer" | TX/RX swapped, 3.3 V missing, EN/RST not on GPIO18 or wrong polarity |
| `fpctl`: "no answer from the token" / "no token found" | The firmware was built with the gate off, or another program (serial monitor) has the port |
| `sudo: ./ctaphid_serial_bridge.py: command not found` | You are not in `desktop/common` |
| Port busy, `/dev/ttyACM0` keeps disappearing | `sudo systemctl stop ModemManager` |
| Permission denied on `/dev/ttyUSB0` | You are not in the `dialout` group yet |
| Everything refused, no touch prompt | No finger enrolled, or sensor not wired |
| Browser says "Touch your security key" forever, the bridge shows **no** `host->token` lines | The browser cannot open the device: udev rule missing (step 8), or a snap/flatpak browser (its sandbox blocks `/dev/hidraw*`; use a `.deb` browser) |
| `FIDO_ERR_OPERATION_DENIED` | The finger was not recognised within the timeout, or no touch happened |
| Token reboots with `Guru Meditation Error` | Firmware bug: keep the backtrace line (file and line number) and open an issue |
| Browser asks to set a PIN | Expected, see step 8 |
| Windows: `the pico_vhf driver is not installed`, `needs an administrator Command Prompt`, device with a yellow mark | See the troubleshooting table in [desktop/windows/README.md](desktop/windows/README.md) |

## 10. Things not to do

- **Do not run `idf.py erase-flash`.** It wipes the token's identity; accounts you registered stop working.
- **Do not run `fido2-token -R`** (FIDO reset): same effect.
- **Windows:** test-signing mode lowers the driver-signature protection of the whole PC; turn it off with
  `desktop\windows\vhid\uninstall.cmd` when you stop using the token.
- **Do not forget your PIN.** After 8 wrong tries it blocks, and the only way out is the reset above, which also needs your finger.
- Re-flashing with plain `idf.py flash` is safe: keys, credentials and fingerprints are kept.
- `fpctl.py` may run while the bridge runs: it then goes through the bridge's local control port (127.0.0.1:47731).
  Do not run two bridges, or the bridge and another serial program, at the same time.

---

# Part B: daily use in 5 steps

1. **Plug the cable into the native USB port.** It powers the board. If the board does not start, also plug the UART port
   (only needed for flashing and logs).
2. **Wait about 3 seconds** for it to boot.
3. **Linux only, after every PC reboot, run once:** `sudo systemctl stop ModemManager` and `sudo modprobe uhid`
   (skip this if you use `desktop/linux/start-bridge.sh` in step 4, it does both). Windows needs nothing here.
4. **Start the bridge and leave the terminal open:**
   ```sh
   desktop/linux/start-bridge.sh       # Linux, or: cd desktop/common && sudo ./ctaphid_serial_bridge.py
   desktop\windows\start-bridge.cmd    # Windows, administrator prompt
   ```
5. **Use your browser.** Enter the PIN if asked, and touch the fingerprint sensor when the bridge prints
   `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<` (within 15 seconds).

Notes: unplugging and replugging the token is fine, the bridge reconnects on its own (restart it if it does not).
Only enrolled fingers work, and the sensor decides; add or remove fingers with `fpctl.py` (the bridge may keep running).

---

## Helper scripts

Three scripts wrap the steps above, with the same menu on every OS: `desktop/linux/*.sh` (bash, they ask for your sudo
password), `desktop/windows/*.cmd` (bridge and FIDO options need an administrator prompt) and, as a concept,
`desktop/mac/*.sh` (bash 3.2).

| Script (Linux / Windows) | What it does |
|---|---|
| `setup-token.sh` / `setup-token.cmd` | Interactive. Stops a running bridge, shows what the token already has (sensor, number of enrolled fingers), then a menu: enrol a finger (the first one, or another), test a finger, delete one or all fingers, initialise the token's keys, create a **new token identity** (FIDO reset), start the bridge. |
| `check-token.sh` / `check-token.cmd` | Read-only status: Linux uhid, udev rule, ModemManager; Windows driver installed; token found, sensor answers, number of fingers, PIN set or not (when the bridge runs). Exit code 0 = ready, 1 = something is missing. |
| `start-bridge.sh` / `start-bridge.cmd` | Only starts the bridge (Linux: after stopping ModemManager and loading `uhid`). Leave it open; Ctrl+C stops it. |

About "generating a token": the token creates its keys by itself the first time it receives a FIDO message, and keeps them
(see *What is stored where*). The menu option "Initialise the token's keys" just sends that first message, so it is safe to
repeat. Creating a **new** identity is the FIDO reset: it erases all registered accounts and the PIN, so the script makes you
type `RESET`, and the token only accepts it within 10 seconds after power-up (the script walks you through the replug).
Fingerprints are never touched by a reset. The Windows `.cmd` scripts were used with the real token; the Linux scripts were
tested against a simulated token, while the flows they wrap (enrolling, testing and deleting fingers, the bridge start,
the status check) were exercised on hardware as in Part A.

---

## Security notes

- The fingerprint gates **user presence**. The token's keys are not encrypted with it, and the ESP32 trusts the sensor
  module's yes/no answer. Someone who can wire their own device to the UART pins, or change the sensor's stored
  fingers, defeats it.
- Flash encryption and secure boot are deliberately **not** enabled (they burn eFuses permanently). Enable and test
  them before relying on this for anything valuable.
- The PIN is a separate secret from the fingerprint, stored by the upstream pico-fido code as a hash in the token's flash.
- This is an educational / experimental device. It is not certified.

## Ideas, not done yet

- Report the fingerprint as built-in user verification so browsers do not ask for a PIN.
- Flash encryption + secure boot.
- Start the bridge as a systemd service / Windows service.
- macOS: get Apple's HID entitlement (paid developer account) and verify the existing helper.
- A properly signed Windows driver (EV certificate, Microsoft attestation), so test-signing mode is not needed.
- A board with native USB device support (for example ESP32-S3) would not need the bridge.

## Repository layout

- `CMakeLists.txt`, `sdkconfig.defaults` (single C6 config), `src/fido2/`
- `pico-keys-sdk/src/usb/serial/` serial framing and transport; `pico-keys-sdk/src/fingerprint/` sensor code
- `pico-fido/src`, `pico-openpgp/src`, `pico-keys-sdk/{src,config,cmake,mlkem,tinycbor}`: upstream code the build uses
- `desktop/`: everything that runs on the PC: `common/` (bridge, `fpctl.py`, host tests), `linux/` (scripts, udev rule), `mac/` (scripts, virtual HID helper; concept), `windows/` (`.cmd` scripts, VHF driver, helper and installer), `issues/` (GitHub issues for the Windows/macOS work)
- `CHANGES.md` (what differs from upstream), `NOTICE.md` (credits and licenses)

## Host tests (no hardware)

```sh
cd desktop/common/tests
python3 run_tests.py            # every test_*.py plus the two C tests of firmware code (needs cc/gcc)
```

The Python tests run on Linux, macOS and Windows (a fake token on a TCP port; on Linux also a fake `/dev/uhid`).
CI runs all of them on the three OSes: `.github/workflows/desktop.yml`. What each test covers and how to test a new
backend without hardware: `desktop/common/tests/README.md`.

## License

AGPL-3.0, because the firmware derives from AGPL-3.0 code. See `LICENSE` and `NOTICE.md`.
