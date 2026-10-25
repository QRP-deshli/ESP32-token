# Options that remove the need for the bridge

The bridge exists because the ESP32-C6 has no USB device controller (only USB-Serial/JTAG), so it cannot be a USB HID
key. Every OS then needs its own virtual HID (Linux: `/dev/uhid`; macOS: an entitled helper, `mac/virtual-hid.md`;
Windows: a driver, `windows/virtual-hid.md`). This compares the ways out. Nothing here is implemented; details marked
"verify" were not checked on hardware.

| | 1. Board with native USB (e.g. ESP32-S3) | 2. CTAP over BLE on the C6 | 3. Keep the bridge |
|---|---|---|---|
| What changes | new board, firmware uses the upstream HID transport (`pico-keys-sdk/src/usb/hid/`) through TinyUSB | firmware gets a FIDO BLE transport (GATT service `0xFFFD`, CTAP framing) | per-OS virtual HID backends |
| PC side | nothing: a normal USB security key | nothing to install, OS Bluetooth pairing | bridge + helper/driver on every PC |
| Linux / macOS / Windows browsers | all (standard USB HID FIDO) | Chrome supports BLE keys on several OSes; Windows/macOS/Firefox support varies (verify) | as far as each backend gets |
| Effort | small to medium: upstream pico-fido already runs on ESP32-S3 (verify the current port), move the fingerprint UART pins | large: new transport, pairing/bonding, power, security review of BLE pairing | large on Windows (driver + signing), medium on macOS (entitlement) |
| Security notes | same as today | BLE pairing and its attack surface; the key is reachable wirelessly | a helper/driver runs on every PC; on Linux the bridge runs as root |
| Cost | a few euros for an S3 board | none | developer accounts / signing certificates for macOS and Windows |

## Recommendation

**Option 1.** An ESP32-S3 (or any board with a USB device controller and enough flash/RAM) makes the token a normal USB
FIDO key on every OS with no software on the PC, and the fingerprint code (`pico-keys-sdk/src/fingerprint/`) is
transport-independent. The C6 build and the bridge can stay for people who already have the hardware. Option 2 is
interesting but is a firmware project of its own; option 3 is the most work for the least gain on Windows.
