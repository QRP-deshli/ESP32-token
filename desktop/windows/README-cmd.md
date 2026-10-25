# Windows without PowerShell: `.cmd` scripts, MinGW tools, MSVC-without-MSBuild driver build

This folder is self-contained for building and installing the driver (it includes the unchanged `driver\` and `pico_vhf_ioctl.h`). Merge it into `desktop\windows\` (same relative paths); the `.ps1` files can stay, nothing here needs them. The scripts expect `..\common\ctaphid_serial_bridge.py` and `fpctl.py` next to the `windows` folder, or set `PICO_BRIDGE_DIR`.

**Nothing in this folder has been run on Windows.** The two C programs were compile-checked with MinGW-w64 only. The
driver build line and the `.cmd` scripts are written from the WDK and cmd documentation. Expect to fix small things on
the first run, and see "Known limits" below.

Tools to install, with links: README-tools.pdf.

## What replaces what

| PowerShell | CMD |
|---|---|
| `common.ps1` | `common.cmd` (library: `call "%LIB%" :label args`) |
| `check-token.ps1` | `check-token.cmd` |
| `start-bridge.ps1` | `start-bridge.cmd` |
| `setup-token.ps1` | `setup-token.cmd` (same menu) |
| `vhid\install.ps1` | `vhid\install.cmd` |
| `vhid\uninstall.ps1` | `vhid\uninstall.cmd` |
| `vhid\setupapi.ps1` (C# SetupAPI via `Add-Type`) | `vhid\installer\pico-install.c` -> `pico-install.exe` |
| MSBuild + `.vcxproj` | `vhid\build.cmd` |

`vhid\helper\pico-vhid.c` has two small changes for MinGW: `#include <winioctl.h>`, and `cbSize` of the interface
detail set to the documented 8 (x64) / 5 (x86) instead of `sizeof()`, which depends on struct packing.

## Build

Needs: Python 3 (runtime), **winlibs MinGW-w64 x86_64** with `gcc` on PATH (tools), Visual Studio 2022 "Desktop
development with C++" plus the matching **WDK** (driver only).

```cmd
desktop\windows\vhid\build.cmd tools     :: pico-vhid.exe + pico-install.exe, MinGW
desktop\windows\vhid\build.cmd driver    :: pico_vhf.sys/.inf/.cat/.cer, cl + link + stampinf + Inf2Cat + signtool
desktop\windows\vhid\build.cmd           :: both
```

`build.cmd driver` finds the WDK and `vcvars64.bat` itself (via `WDKContentRoot` / `vswhere`). Overrides: `WDKVER`,
`KMDF_VER` (default 1.15), `WERROR=1`. It creates the test certificate `CN=PicoVhfTestCert` in your personal store the
first time (`makecert`, or one PowerShell command if this WDK has no `makecert.exe`).

## Install and use (administrator Command Prompt)

```cmd
desktop\windows\vhid\install.cmd         :: test-signing (reboot, Secure Boot off), trust the test cert, create device, install driver
desktop\windows\setup-token.cmd          :: fingers, keys, reset (menu)
desktop\windows\start-bridge.cmd         :: daily; leave the window open
desktop\windows\check-token.cmd          :: read-only status, exit code 0 = ready
desktop\windows\vhid\uninstall.cmd
```

## Differences from the PowerShell scripts

- **"Is the bridge running?"** `start-bridge.cmd` holds an exclusive lock on `%TEMP%\pico-fido2-bridge.lock`; the other
  scripts test it. There is no process-command-line lookup (that would need `wmic`, gone from current Windows 11).
- **Stopping a bridge.** A bridge in your own window is closed with Ctrl+C there; `setup-token.cmd` and `check-token.cmd`
  tell you when to do that instead of killing it. Only the background bridge that `setup-token.cmd` itself starts
  (minimised window `PICO_BG_BRIDGE`) is stopped by the scripts. `check-token.cmd` no longer offers to stop the bridge.
- `Ctrl+C` in `start-bridge.cmd` may ask "Terminate batch job (Y/N)?"; answer Y.
- Prompts are plain `[y/N]` text, no colours.

## Known limits

- `install.cmd` / `uninstall.cmd` look for `testsigning  Yes` in `bcdedit` output, which is English only.
- A package built elsewhere (CI artifact, MSBuild) has no `pico_vhf.cer`; `install.cmd` then extracts the signer
  certificate from the `.cat` with one `powershell -Command` line (the only PowerShell left, and only in that case).
- `uninstall.cmd` removes only the `PicoVhfTestCert` certificate; one from another build is removed in `certmgr.msc`.
- The driver's compiler/linker flags follow what the WDK MSBuild targets pass, but could not be compared against a real
  MSBuild log. If `cl`/`link` complain, run the same project once with MSBuild `/v:diag`, and adjust `CFLAGS`, `DEFS` and
  the `link` line in `build.cmd` to match.
