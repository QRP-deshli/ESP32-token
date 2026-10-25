# Host tests (no hardware)

```sh
python3 run_tests.py            # everything: every test_*.py, then the two C tests (needs cc/gcc, or set CC)
python3 run_tests.py --no-c     # Python only
python3 run_tests.py control    # only tests whose file name contains "control"
```

CI (`.github/workflows/desktop.yml`) runs `run_tests.py` on Linux, macOS and Windows. A new `test_*.py` file is picked
up automatically. Each test prints `PASS`/`FAIL` lines, exits 1 on any failure, and skips what its OS cannot run.

| Test | What it covers | Runs on |
|---|---|---|
| `test_layout.py` | no OS-specific code in the protocol module, the bridge or `fpctl.py` (static, AST) | all |
| `test_serial_link.py` | port detection: Windows registry (fake `winreg`), macOS and Linux device names (fake `glob`) | all |
| `test_windows_serial.py` | `WindowsSerial` against a fake `kernel32` (DCB, DTR/RTS, timeouts, unplug) | all |
| `test_posix_serial.py` | `PosixSerial` on a pty (raw mode, bauds, unplug, exclusive open on macOS) | Linux, macOS |
| `test_fpctl.py` | every `fpctl.py` command against a fake token, over TCP and a pty | all (pty: Linux, macOS) |
| `test_bridge_e2e.py` | bridge end to end with an in-memory HID, a fake helper process, `--no-hid` replug, and Linux uhid | all (uhid: Linux) |
| `test_control.py` | `fpctl.py` through a running bridge's control port | all |
| `test_scripts.py` | this OS's `check-token` script against a fake token | all |
| `test_setup_scripts.py` | this OS's `setup-token` menu (enrol, test, delete, delete all) with typed answers | all |
| `test_mac_helper.py` | the built `pico-vhid` without the HID entitlement | macOS, after `mac/vhid/build.sh` |
| `test_fp_core.c`, `test_serial_proto.c` | firmware code: fingerprint state machine, serial frame codec | all (gcc / clang) |

## The fakes

- **Fake token** (`fake_token.py`): speaks the serial frame protocol on a TCP port (`tcp://127.0.0.1:N`, every OS) or a
  pty (Linux, macOS). Pass a handler `handler(ftype, data, send)`; PING is answered for you. `unplug()` drops the TCP
  connection, `inject()` writes raw bytes (noise, broken frames). Point a tool at it with `--port` or `PICO_TOKEN_PORT`.
- **Fake virtual HID**: any `VirtualHid` subclass with in-memory queues (see `FakeHid` in `test_bridge_e2e.py`), or a
  Python script as `HelperProcessHid` helper, or (Linux) a `SOCK_SEQPACKET` socketpair as `/dev/uhid`.
- **Fake OS APIs**: `test_serial_link.py` replaces `winreg`, `test_windows_serial.py` replaces `ctypes.WinDLL` with
  objects that record what the backend asked for.

## Covering a new backend without hardware

- A **serial backend** (`serial_link.py`): fake the OS API it calls, the way `test_windows_serial.py` fakes `kernel32`.
  Check the settings it makes (timeouts, control lines) and that errors after an unplug become `LinkClosed`.
- A **virtual HID backend** (`virtual_hid.py`): if it is a helper program, start the bridge with it against the fake
  token, as the `[helper]` part of `test_bridge_e2e.py` does. Otherwise subclass-test it with in-memory queues.
- A **helper program** that cannot run in CI (needs a driver or an entitlement): test that it refuses clearly, like
  `test_mac_helper.py`.
