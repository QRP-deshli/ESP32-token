# macOS: virtual FIDO device

Linux creates the virtual FIDO device through `/dev/uhid`. macOS has no such file; a user program can create a virtual
HID device only through Apple's APIs, and those need an entitlement.

## Options

| Option | What it is | Needs | Effort | Verdict |
|---|---|---|---|---|
| `IOHIDUserDevice` (IOKit, C API) | user-space virtual HID device, `IOHIDUserDeviceCreateWithProperties` | macOS 10.15+, entitlement `com.apple.developer.hid.virtual.device` | small helper | **chosen** |
| CoreHID `HIDVirtualDevice` (Swift) | the same feature as a Swift actor | macOS 15+, the same entitlement | small helper | later, if 10.15–14 support can be dropped |
| DriverKit `IOUserHIDDevice` | a system extension that is a HID device | a DriverKit entitlement, a signed app that installs the extension, user approval in System Settings | large | not worth it for a 64-byte report pipe |

Both user-space APIs are documented in the SDK headers (`IOKit/hidsystem/IOHIDUserDevice.h`: "the entitlement
`com.apple.developer.hid.virtual.device` is required"; `CoreHID.framework`). Python cannot call either directly, so the
bridge starts a small helper and passes reports over its stdin/stdout (protocol in `desktop/common/virtual_hid.py`).

Browsers on macOS (Chrome, Firefox, Safari via the system) find security keys through IOKit HID, matching usage page
`0xF1D0`. A device made with `IOHIDUserDevice` is an `IOHIDDevice` in the kernel, so it is found the same way as a real
key. **Not verified on hardware yet.**

## The helper: `vhid/pico-vhid`

`vhid/main.swift` (about 150 lines) creates the device with `FIDO_REPORT_DESC`, writes output reports from the OS to
stdout and hands input reports from stdin to the OS. The bridge starts it automatically on macOS.

```sh
desktop/mac/vhid/build.sh                               # build only: ad-hoc signature, NO entitlement
desktop/mac/vhid/build.sh "Apple Development: you (ID)" # build and sign with the entitlement
```

What was tested on macOS 27 (Apple silicon), without the token:

- it compiles with the Xcode command line tools;
- signed ad-hoc **with** the entitlement, macOS kills it at start (`SIGKILL`, exit 137): a restricted entitlement
  needs a provisioning profile, an ad-hoc signature is not enough. That is why `build.sh` leaves the entitlement out
  when no identity is given;
- signed ad-hoc **without** the entitlement, `IOHIDUserDeviceCreateWithProperties` returns NULL and the helper exits with
  a clear message; the bridge then logs `virtual HID helper exited (status 1)` and stops.

## Getting the entitlement

`com.apple.developer.hid.virtual.device` is a restricted (managed) entitlement. To be verified by whoever does this:

1. A paid Apple Developer Program membership; request the "HID Virtual Device" capability for your team from Apple
   (Certificates, Identifiers & Profiles, or the capability request form).
2. Create an App ID with the capability, a development provisioning profile that includes it, and a signing identity.
3. Because `pico-vhid` is a bare command-line tool, macOS only honours the profile when the binary is inside an app
   bundle (`pico-vhid.app/Contents/embedded.provisionprofile`). If plain signing is refused, wrap it in a minimal
   bundle and point the bridge at it with `--helper path/to/pico-vhid.app/Contents/MacOS/pico-vhid`.

For local development only, the entitlement check can be relaxed by disabling System Integrity Protection and AMFI
(`csrutil disable` in Recovery, then `sudo nvram boot-args="amfi_get_out_of_my_way=1"`). **This removes important
protections from the whole Mac**; do it only on a test machine and undo it afterwards (`csrutil enable`,
`sudo nvram -d boot-args`).

## Removing it

Stop the bridge (Ctrl+C); the device disappears when the helper exits. Delete `desktop/mac/vhid/pico-vhid`. Nothing is
installed outside the repository.
