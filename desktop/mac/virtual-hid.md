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

**Decision: `IOHIDUserDevice` in a small Swift helper** (`vhid/`). It needs the same entitlement as CoreHID but works
from macOS 10.15, and a user-space helper is far less to install and sign than a DriverKit system extension.

### How browsers reach the device

- Chrome and Edge enumerate HID devices with `IOHIDManager` and pick FIDO keys by usage page `0xF1D0`, usage `0x01`.
- Firefox does the same through its `authenticator-rs` HID backend.
- Safari does not talk HID itself: it uses the system's WebAuthn implementation (AuthenticationServices), which also
  reaches USB security keys as HID devices.

A device made with `IOHIDUserDevice` is a real `IOHIDDevice` in the kernel, published with the FIDO report descriptor
and `PrimaryUsagePage`/`PrimaryUsage` set, so all of them should find it like a plugged-in key. **Not verified with a
browser yet** (no entitlement and no token were available).

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
3. Download the profile and build the app bundle with it:

   ```sh
   desktop/mac/vhid/build.sh "Apple Development: you (TEAMID)" ~/Downloads/PicoVHID.provisionprofile
   desktop/mac/vhid/pico-vhid --check      # "OK: the virtual HID device can be created"
   ```

   `build.sh` reads the App ID from the profile, writes `PicoVHID.app/Contents/Info.plist` with that bundle identifier,
   embeds the profile, signs the bundle with the entitlement and links `pico-vhid` into it (the bridge's default path).
   A bare binary signed with the entitlement but without a profile is killed by macOS at start (exit 137).

For local development only, the entitlement check can be relaxed by disabling System Integrity Protection and AMFI
(`csrutil disable` in Recovery, then `sudo nvram boot-args="amfi_get_out_of_my_way=1"`). **This removes important
protections from the whole Mac**; do it only on a test machine and undo it afterwards (`csrutil enable`,
`sudo nvram -d boot-args`).

## Removing it

Stop the bridge (Ctrl+C); the device disappears when the helper exits. Delete `desktop/mac/vhid/pico-vhid` and
`desktop/mac/vhid/PicoVHID.app`. Nothing is installed outside the repository; revoke the provisioning profile in the
developer portal if you no longer need it.

## Checks without hardware

`desktop/common/tests/test_mac_helper.py` (run in CI on macOS) builds nothing itself; after `build.sh` it checks that
the helper without the entitlement refuses with a clear message and that the bridge stops with that reason.
`check-token.sh` runs `pico-vhid --check`, so it reports whether this Mac can really create the device.
