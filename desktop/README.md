# Desktop side: everything that runs on the PC

The token (ESP32-C6) speaks CTAPHID over its native USB-Serial/JTAG port, which the PC sees as a serial port. To use it
as a FIDO key, the PC needs two things:

1. a **serial link** to the token (find the port, open it, exchange the frames defined in
   `pico-keys-sdk/src/usb/serial/serial_proto.h`), and
2. a **virtual USB HID FIDO device** that browsers and libfido2 can use, fed from that serial link.

The same Python code does both (`common/`), but the virtual-device part and the helper scripts are operating-system
specific.

| Folder | What is in it | Status |
|---|---|---|
| `common/` | `ctaphid_serial_bridge.py` (serial link + virtual HID bridge), `fpctl.py` (fingerprint admin), host tests in `tests/` | works on **Linux**; uses Linux-only APIs (see the issues) |
| `linux/` | `setup-token.sh`, `check-token.sh`, `start-bridge.sh`, `common.sh`, udev rule | **works** (tested on Ubuntu with Brave) |
| `windows/` | | **not implemented**, see `windows/README.md` |
| `mac/` | | **not implemented**, see `mac/README.md` |
| `issues/` | GitHub issues for the Windows/macOS work, plus a script that files them | |

## Using it on Linux

Everything you need is in `linux/` and `common/`. From the repository root:

```sh
desktop/linux/setup-token.sh     # guided: fingers, keys, new identity, then offers to start the bridge
desktop/linux/check-token.sh     # status only
desktop/linux/start-bridge.sh    # every day: starts the bridge (leave it open)
```

Browsers additionally need the udev rule once (`desktop/linux/70-pico-fido2.rules`). The full step-by-step manual is in
the top-level `README.md`.

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
