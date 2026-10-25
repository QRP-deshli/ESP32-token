---
title: "(discussion) Options that remove the need for the bridge"
labels: desktop,research
---
## Why

The bridge exists because the ESP32-C6 has no USB device controller (only USB-Serial/JTAG), so it cannot be a USB HID
key. Every OS then needs its own virtual-HID solution (issues 03 and 05). Before investing heavily in them it is worth
comparing the alternatives, since each would make Windows, macOS and Linux behave the same.

## Where to look

- Firmware transport: `pico-keys-sdk/src/usb/serial/` (what the C6 uses today), `CMakeLists.txt` (`USB_TRANSPORT_SERIAL`).
- The upstream HID transport used on boards with native USB: `pico-keys-sdk/src/usb/hid/hid.c` and the USB code in
  `pico-keys-sdk/src/usb/`.

## Options to evaluate (all to be verified, none is decided)

1. **A board with native USB device support** (for example an ESP32-S3 or similar), using the upstream HID transport. No
   bridge at all. Check ESP-IDF/TinyUSB support, flash/RAM, the fingerprint UART, and what upstream's ESP32 port already
   supports.
2. **CTAP2 over Bluetooth Low Energy** on the C6 (it has BLE): FIDO2 defines a BLE transport. Check which OS/browser
   combinations support BLE security keys and how pairing works; this is a large firmware task.
3. **Keep the bridge** and invest in per-OS virtual HID (issues 03 and 05).

## Acceptance criteria

- A short written comparison (effort, user experience, which OS/browsers work, security notes) and a recommendation.
- No code is required for this issue.
