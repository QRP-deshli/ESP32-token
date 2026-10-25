# Windows virtual FIDO device: `pico_vhf` driver + `pico-vhid.exe`

Option 2 of [../virtual-hid.md](../virtual-hid.md): a small KMDF driver on top of Microsoft's Virtual HID Framework
(VHF), and a helper that the bridge starts. Build, install and use are described in [../README.md](../README.md)
(sections 2, 3, 5); this page is the technical part.

```
browser -> webauthn.dll -> HID class -> [vhf.sys | pico_vhf.sys]  <-IOCTLs->  pico-vhid.exe  <-stdin/stdout->  bridge  <-COM->  token
```

| File | What it is |
|---|---|
| `driver/pico_vhf.c`, `.inf`, `.vcxproj` | the driver. Root-enumerated (`Root\PicoVhf`), `vhf.sys` as lower filter. Creates the HID device (FIDO report descriptor, VID/PID from the helper) when the helper asks, removes it when the helper's handle closes. One helper at a time. |
| `helper/pico-vhid.c` | the helper: bridge protocol on stdin/stdout (see `desktop/common/virtual_hid.py`), IOCTLs to the driver |
| `installer/pico-install.c` | creates / installs / removes the `Root\PicoVhf` device (what `devcon install` does) |
| `pico_vhf_ioctl.h` | the IOCTLs and the device interface GUID they share |
| `build.cmd`, `install.cmd`, `uninstall.cmd` | build (MinGW + `cl`/`link`, no MSBuild), install, remove |

## Access restriction

Only SYSTEM and administrators can open the driver. This is set by the `Security` value in `pico_vhf.inf`
(`HKR,,Security,,"D:P(A;;GA;;;SY)(A;;GA;;;BA)"`), not by `WdfDeviceInitAssignSDDLString` in the driver code: with that
call the device failed to start (problem code 31, status `0xC0000079`).

## Build notes

- `build.cmd driver` does what the MSBuild project does, by hand: `cl /kernel`, `link /DRIVER`, `stampinf`, `Inf2Cat`,
  `signtool`, with the WDK found through `WDKContentRoot` or `Program Files (x86)\Windows Kits\10`. If `cl` or `link`
  complain after a WDK update, run `msbuild pico_vhf.vcxproj /v:diag` once and compare with `CFLAGS`, `DEFS` and the
  `link` line in `build.cmd`.
- `vhf.h` is in `Include\<version>\shared`, the import library `vhfkm.lib` in `Lib\<version>\km\x64`.
- CI (`windows-vhid` job in `.github/workflows/desktop.yml`) builds the helper with MinGW and the driver with MSBuild.
- `pico-vhid.c` has `#include <winioctl.h>` and sets `cbSize` of the interface detail to the documented 8 (x64) / 5
  (x86), for MinGW.

## Debugging

Device Manager, `pnputil /enum-devices /problem` (problem code and status), `sc query pico_vhf`, DebugView for kernel
messages.

## Security notes

- The driver is a kernel component; a bug in it can crash Windows. It does little (copies 64-byte reports).
- Its control device is limited to SYSTEM and administrators and is exclusive, so a normal process cannot feed reports
  to the browser.
- Test-signing mode weakens Windows' driver-signature enforcement for the whole machine.
