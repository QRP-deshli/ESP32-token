# Windows: virtual FIDO device (research)

Linux creates the virtual FIDO device through `/dev/uhid`. Windows has nothing a normal user program can use for that,
so today **the bridge cannot run on Windows without an external helper**. The serial side (`fpctl.py`, token detection)
works without it.

The bridge already has the hook: `--helper PROGRAM` (or the `PICO_VHID_HELPER` environment variable) starts a program
that owns the virtual device and passes 64-byte reports over its stdin/stdout. The protocol is at the top of
`desktop/common/virtual_hid.py`; `desktop/mac/vhid/main.swift` is a complete example for macOS. A Windows helper only
has to implement the same protocol.

## How browsers reach security keys on Windows

Since Windows 10 1903, browsers (Chrome, Edge, Firefox) do not open FIDO HID devices themselves: they call the Windows
WebAuthn API (`webauthn.dll`), and the OS talks to the key. Programs without administrator rights cannot open FIDO HID
devices directly. Consequences:

- a virtual HID device must be a real HID device in the kernel, visible to the WebAuthn service; a user-mode-only fake is
  not enough;
- `fido2-token -L` (libfido2) lists HID keys only when run as administrator; without it, libfido2 goes through
  `webauthn.dll` and shows `windows://hello`. The helper scripts note this.

## Options

| Option | What it is | Needs | Effort | Notes |
|---|---|---|---|---|
| 1. WebAuthn plugin authenticator API | Windows 11 passkey-provider plugins (`webauthn.dll` plugin model): the OS calls a registered app instead of a HID device | a recent Windows 11 build with plugin support, an MSIX-packaged COM server, registration with the OS | large | The plugin receives CTAP2 CBOR requests; the bridge would wrap them in CTAPHID frames for the token. Aimed at passkey managers (platform-style UI); whether a roaming "security key" behaves the same, and which builds have it, must be verified. |
| 2. Virtual HID Framework (VHF) driver | a small KMDF driver that calls `VhfCreate` with `FIDO_REPORT_DESC` and passes reports to user mode (IOCTLs) | the WDK, driver signing (test-signing for development: `bcdedit /set testsigning on`, needs admin; release needs an EV certificate and Microsoft attestation signing) | medium | Exactly the uhid model: the OS sees a HID FIDO key. The user-mode side is a small helper speaking the stdin/stdout protocol. Microsoft's VHF sample is the starting point. |
| 3. UMDF HID minidriver (`mshidumdf`) | user-mode driver variant of option 2 | same signing story, a bit easier to debug | medium | Microsoft's "vhidmini2" sample. |
| 4. Third-party virtual USB / USB-over-IP (usbip-win2, commercial virtual HID drivers) | a generic virtual-device driver someone else signed | installing a third-party kernel driver | small to medium | No own driver, but a dependency on that project's signing and maintenance. usbip-win2 would let the Linux bridge's device be exported over the network instead. |
| 5. No bridge at all | see `../no-bridge-options.md` | different hardware or BLE | | Removes the problem on every OS. |

## Recommendation

**Option 2 (VHF driver + small user-mode helper)** for a prototype: it gives the same model as Linux (a real HID FIDO
device), works with every browser through `webauthn.dll`, and test-signing is enough for development. Start from the
Windows-driver-samples `hid/vhidmini2` (UMDF) or the VHF documentation, and implement the helper protocol in the
user-mode part. Revisit option 1 once Microsoft's plugin model is generally available, since it would avoid a driver.

Before choosing, also read `../no-bridge-options.md`: an ESP32-S3 (native USB) removes the need for any of this.

## Not done yet

- no helper exists; none of the options above was prototyped;
- install/uninstall steps and admin rights depend on the option (test-signing and driver install need administrator);
- browser registration on Windows was not tested.
