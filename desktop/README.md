# Desktop side: everything that runs on the PC

The token (ESP32-C6) speaks CTAPHID over its native USB-Serial/JTAG port, which the PC sees as a serial port. To use it
as a FIDO key, the PC needs two things:

1. a **serial link** to the token (find the port, open it, exchange the frames defined in
   `pico-keys-sdk/src/usb/serial/serial_proto.h`), and
2. a **virtual USB HID FIDO device** that browsers and libfido2 can use, fed from that serial link.

The Python code in `common/` does both. The operating-system specific parts sit behind two small interfaces:

| Module | What it is | Backends |
|---|---|---|
| `serial_frames.py` | the frame protocol (CRC, encoder, streaming decoder); no OS-specific imports | |
| `serial_link.py` | `SerialLink` (open, read with timeout, write, close) and port detection | `PosixSerial` (termios: Linux, macOS), `WindowsSerial` (ctypes + kernel32), `SocketLink` (`tcp://host:port`, tests) |
| `virtual_hid.py` | `VirtualHid` (create, poll output reports, send input reports, close); `open_virtual_hid()` picks the backend for this OS | `UhidDevice` (Linux), `HelperProcessHid` (a native helper over stdin/stdout: macOS `mac/vhid`, Windows later) |
| `multiplex.py` | `wait_readable()`: `select()` where every source has a file descriptor, otherwise the caller polls | |
| `ctaphid_serial_bridge.py` | the `Bridge` that moves 64-byte reports between the two, and its command line | |
| `fpctl.py` | fingerprint admin over the serial link, or through a running bridge | |
| `control.py` | the bridge's control port (127.0.0.1:47731, `$PICO_CONTROL_PORT`, `--no-control`): passes fingerprint admin frames between `fpctl.py` and the token | |

A new backend is added in `serial_link.py` (`open_link`, `list_ports`) or `virtual_hid.py` (`open_virtual_hid`) without
touching `Bridge` or `fpctl.py`; `tests/test_layout.py` fails if OS-specific imports, platform checks or `/dev` paths
appear in the bridge, `fpctl.py` or the protocol module. `--port` defaults to `$PICO_TOKEN_PORT` and `--helper` to
`$PICO_VHID_HELPER`.

**Decision: standard library only, no pyserial.** pyserial would have saved the Windows backend (about 120 lines of
`ctypes` around `CreateFileW`, `SetCommState`, `SetCommTimeouts`, `ReadFile`/`WriteFile`) and the port listing. Against
it: the bridge runs as root on Linux (`sudo`), where installing a package means either a system package or `sudo pip`;
the helper scripts would need a dependency check on every OS; and the project has been dependency-free so far. The
cost of staying stdlib-only is that `WindowsSerial` and the registry-based port detection are our own code, covered by
host tests (`test_serial_link.py` with a fake `winreg`) but not yet run against the token. If that code becomes a
maintenance problem, `WindowsSerial` can be replaced by a pyserial-based `SerialLink` without touching anything else.

| Folder | What is in it | Status |
|---|---|---|
| `common/` | the modules above, host tests in `tests/` | host tests pass on Linux, macOS and Windows (CI) |
| `linux/` | `setup-token.sh`, `check-token.sh`, `start-bridge.sh`, `common.sh`, udev rule | **works** (tested on Ubuntu with Brave) |
| `mac/` | the same scripts (bash 3.2), `vhid/` virtual HID helper (Swift) | **concept only**: serial side works with the token, the virtual device needs Apple's HID entitlement (paid developer account), not pursued; see `mac/README.md` |
| `windows/` | the same scripts (`.cmd`), `vhid/` VHF driver, helper and installer | **works** (tested with the token: driver, bridge, `fpctl.py`, browser registration), see `windows/README.md` |
| `issues/` | GitHub issues for the Windows/macOS work, plus a script that files them | |
| `no-bridge-options.md` | comparison of ways to drop the bridge altogether | |

## Using it on Linux

Everything you need is in `linux/` and `common/`. From the repository root:

```sh
desktop/linux/setup-token.sh     # guided: fingers, keys, new identity, then offers to start the bridge
desktop/linux/check-token.sh     # status only
desktop/linux/start-bridge.sh    # every day: starts the bridge (leave it open)
```

Browsers additionally need the udev rule once (`desktop/linux/70-pico-fido2.rules`). The full step-by-step manual is in
the top-level `README.md`.

## fpctl.py while the bridge runs

The bridge owns the serial port, so it offers a local control port: `fpctl.py` connects to 127.0.0.1:47731 when a
bridge answers there, and opens the serial port itself otherwise. Only fingerprint admin frames pass (one client at a
time); CTAPHID traffic is not delayed. If a browser and `fpctl.py` need the sensor at the same moment, the token answers
one of them "the sensor is busy, try again". Only local programs can connect, and changing fingerprints still needs a
touch with an enrolled finger (except the very first enrolment). `--no-control` turns the port off.

The helper scripts still stop the bridge before changing fingers; they can be simplified to use the control port.

## Helper scripts on each OS

| | Linux (`linux/*.sh`) | macOS (`mac/*.sh`, bash 3.2) | Windows (`windows/*.cmd`) |
|---|---|---|---|
| system preparation | `sudo`: stop ModemManager, load `uhid` | none (no sudo, no driver) | none; bridge and `fido2-token` need an administrator PowerShell |
| virtual device check | `/dev/uhid`, udev rule | `vhid/pico-vhid --check` | `vhid\pico-vhid.exe`, `Root\PicoVhf` driver installed |
| bridge process | `pgrep`/`pkill` | `pgrep`/`pkill` (also matches Homebrew's `Python`) | `Get-CimInstance Win32_Process` / `Stop-Process` |
| FIDO device for `fido2-token` | `/dev/hidrawN` | `ioreg://…` | `\\?\hid#…` |
| menu, wording, `RESET` confirmation, exit codes | reference | same | same |
| tested | with the token | menu against a fake token (CI); concept only | with the token |

`tests/test_scripts.py` and `tests/test_setup_scripts.py` run each OS's `check-token` and `setup-token` (enrol, test,
delete, delete all) against a fake token in CI.

### FIDO reset and the 10-second window

The token accepts a reset only in the first 10 seconds after power-up. After the replug the flow needs:

| Step | Time |
|---|---|
| token boots and its USB port appears | about 1 s (to measure) |
| the bridge notices (retries every 1 s, PING/PONG probe up to 0.6 s per candidate port) | up to about 1.6 s |
| the script sees "token on" in the bridge log (polls every 0.5 s) | up to 0.5 s |
| the virtual FIDO device is found (`fido2-token -L`, polls every 0.5 s) | usually immediately; it stays up while the token is away |
| `fido2-token -R` reaches the token | well under 1 s |

That is about 3–4 s, leaving margin for the finger touch. On macOS and Windows the script now detects the replug by
itself; earlier it asked to wait about 3 seconds and press Enter, which spent part of the window on the person. The Linux
script still asks for Enter (unchanged, it worked in testing). None of this was timed on hardware for macOS or Windows.

## Using it on Windows (or macOS)

See `windows/README.md`. macOS is a concept only (`mac/README.md`): without Apple's HID entitlement the bridge cannot
create the virtual device there.

## Working on Windows or macOS support

Start with `issues/00-epic.md`. The firmware does not change; the work is on the PC side. The issues are written as
Markdown files with a small front matter (title, labels); `issues/create-issues.sh` files them with the GitHub CLI.
To file the issues on GitHub (once; needs the [GitHub CLI](https://cli.github.com) and `gh auth login`):

```sh
cd desktop/issues
./create-issues.sh --dry-run          # list them
./create-issues.sh owner/repo        # create them
```

To try your changes you need the same hardware as in the top-level README (ESP32-C6-DevKitC-1, fingerprint module) with the
firmware flashed.
