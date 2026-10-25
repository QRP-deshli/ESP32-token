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
| `fpctl.py` | fingerprint admin over the serial link | |

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
| `mac/` | the same scripts (bash 3.2), `vhid/` virtual HID helper (Swift) | implemented, **not tested with the token**; the helper needs an Apple entitlement, see `mac/README.md` |
| `windows/` | the same scripts (PowerShell), virtual HID research | serial side implemented, **not tested with the token**; no virtual HID backend yet, see `windows/README.md` |
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

## Using it on macOS or Windows

See `mac/README.md` and `windows/README.md`.

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
