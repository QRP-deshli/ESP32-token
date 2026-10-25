# Linux

Works today (Ubuntu, Brave). Needs: bash, Python 3, `sudo`, the `uhid` kernel module, `fido2-tools` (for the optional
FIDO checks), and for browsers the udev rule below.

| File | Purpose |
|---|---|
| `setup-token.sh` | interactive: shows fingers enrolled, enrol/test/delete, initialise keys, new token identity (FIDO reset), start bridge |
| `check-token.sh` | read-only status; exit code 0 = ready |
| `start-bridge.sh` | stops ModemManager, loads `uhid`, runs `../common/ctaphid_serial_bridge.py` as root |
| `common.sh` | helpers shared by the three scripts (sourced) |
| `70-pico-fido2.rules` | udev rule so a browser, running as your user, may open the virtual `/dev/hidrawN` |

Browser setup, once:

```sh
sudo cp desktop/linux/70-pico-fido2.rules /etc/udev/rules.d/
sudo udevadm control --reload
# restart the bridge afterwards: the device node is created when the bridge starts
```

Linux-only things used here, which Windows and macOS need other answers for: `/dev/uhid` (virtual HID), `/dev/hidrawN`,
udev, `termios` serial access, `systemctl stop ModemManager`, `modprobe`, `pkill`, `sudo`.
