# Windows virtual FIDO device: `pico_vhf` driver + `pico-vhid.exe`

Prototype of option 2 in [../virtual-hid.md](../virtual-hid.md): a small KMDF driver on top of Microsoft's Virtual HID
Framework (VHF), and a helper that the bridge starts.

```
browser -> webauthn.dll -> HID class -> [vhf.sys | pico_vhf.sys]  <-IOCTLs->  pico-vhid.exe  <-stdin/stdout->  bridge  <-COM->  token
```

| File | What it is |
|---|---|
| `driver/pico_vhf.c`, `.inf`, `.vcxproj` | the driver. Root-enumerated (`Root\PicoVhf`), `vhf.sys` as lower filter. Creates the HID device (FIDO report descriptor, VID/PID from the helper) when the helper asks, removes it when the helper's handle closes. Only administrators can open it, one at a time. |
| `helper/pico-vhid.c` | the helper: bridge protocol on stdin/stdout (see `desktop/common/virtual_hid.py`), IOCTLs to the driver |
| `pico_vhf_ioctl.h` | the IOCTLs and the device interface GUID they share |
| `install.ps1`, `uninstall.ps1`, `setupapi.ps1` | install/remove the driver (no `devcon` needed) |

## Status

- Built in CI (`windows-vhid` job in `.github/workflows/desktop.yml`), artifact `pico-vhf-windows-x64`.
- **Never installed or run**: no Windows test machine and no token were available. Expect to debug the first install
  (Device Manager, `pnputil /enum-devices /problem`, DebugView for kernel messages).

## Build

On a Windows 10/11 PC with Visual Studio 2022 ("Desktop development with C++") and the matching Windows Driver Kit
(WDK), from a "Developer PowerShell for VS 2022":

```powershell
msbuild desktop\windows\vhid\driver\pico_vhf.vcxproj /p:Configuration=Release /p:Platform=x64
cl /O2 /Fe:desktop\windows\vhid\pico-vhid.exe desktop\windows\vhid\helper\pico-vhid.c setupapi.lib
```

The driver package (`pico_vhf.sys`, `.inf`, `.cat`, test-signed with the WDK test certificate) lands in
`driver\x64\Release\pico_vhf\`. Instead of building, you can download both from the CI artifact; put `pico-vhid.exe` in
`desktop\windows\vhid\` and the `pico_vhf` folder in `driver\x64\Release\`.

## Install (administrator)

```powershell
powershell -ExecutionPolicy Bypass -File desktop\windows\vhid\install.ps1
```

It asks before each system change:

1. **Test-signing mode** (`bcdedit /set testsigning on`, then a reboot; run the script again afterwards). Needs Secure
   Boot off. Test-signing lets any test-signed driver load, so turn it off when you stop using this (`uninstall.ps1`).
2. **Trust the WDK test certificate** that signed the package (Trusted Root and Trusted Publishers of this machine).
3. **Create `Root\PicoVhf` and install the driver** (SetupAPI, like `devcon install`).

Device Manager then shows "Pico FIDO2 virtual HID source (serial bridge)" under Human Interface Devices. The FIDO HID
device itself appears only while the bridge runs.

## Use

From an **administrator** PowerShell (the driver lets only administrators in):

```powershell
desktop\windows\start-bridge.ps1
```

The bridge starts `pico-vhid.exe`, which creates the FIDO HID device (`1D50:619B`). Then register on
https://www.token2.com/tools/fido2-demo in Edge or Chrome; the bridge window shows when to touch the sensor. Browsers
reach the device through Windows' WebAuthn service, so they need no special rights.

## Uninstall (administrator)

```powershell
powershell -ExecutionPolicy Bypass -File desktop\windows\vhid\uninstall.ps1
```

Removes the device and the driver package, then asks whether to remove the test certificate and turn test-signing off.

## What needs administrator rights

| Step | Admin? |
|---|---|
| install / uninstall | yes |
| running the bridge (opening the driver) | yes |
| `fpctl.py`, `setup-token.ps1` fingerprint options | no |
| using the token in a browser | no |
| `fido2-token -L` / `-I` on the device | yes (Windows limits direct FIDO HID access to administrators) |

## Security notes

- The driver is a kernel component; a bug in it can crash Windows. It does little (copies 64-byte reports), but it was
  not tested.
- Its control device is limited to SYSTEM and administrators and is exclusive, so a normal process cannot feed reports
  to the browser.
- Test-signing mode weakens Windows' driver-signature enforcement for the whole machine. A production setup would need
  an EV code-signing certificate and Microsoft attestation signing.
