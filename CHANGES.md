# Changes compared with upstream pico-fido2

**ESP32-C6 port**
- The C6 has no USB device controller, so CTAPHID is carried over the native USB-Serial/JTAG port
  (`pico-keys-sdk/src/usb/serial/`); `desktop/common/ctaphid_serial_bridge.py` turns it into a virtual USB HID
  FIDO device on Linux (uhid).
- Slim, C6-only tree; single `sdkconfig.defaults`; OATH/OTP/CCID apps are off (FIDO2/U2F only).
- Build fixes found during bring-up: C6 detection from `-DIDF_TARGET`, component requirements decided through the
  environment, OATH/OTP macros left undefined when off (link errors), clean sdkconfig.

**Fingerprint gate** (`pico-keys-sdk/src/fingerprint/`)
- User presence = a fingerprint match on a Waveshare-style UART fingerprint module. Fails closed.
- ON by default for the C6 serial build (`-DENABLE_FINGERPRINT=OFF` to disable for bench tests).
- Enrol/delete over the bridge's serial port with `desktop/common/fpctl.py`; the first finger needs no
  authorisation, later changes need an enrolled finger.
- The sensor is woken/reset through its enable/reset pin (GPIO18) when it stops answering.

**Bug fixes in upstream code**
- `cbor_make_credential.c`: registration never asked for user presence when the client sent no PIN auth parameter
  (e.g. `fido2-cred`, or any token with no PIN set). It now always requires user presence.
- `cbor_client_pin.c`: `getPINRetries` dereferenced a NULL pointer when no PIN was set, crashing the token as soon as a
  browser asked (Brave/Chrome do this first). It now reports the full retry count (8).

**Host tools**
- Bridge prints `>>> TOUCH THE FINGERPRINT SENSOR NOW <<<` for every wait for user presence.
- `70-pico-fido2.rules` (udev) lets browsers open the virtual device.
- `desktop/linux/`: `setup-token.sh` (guided fingers / keys / reset), `check-token.sh` (status), `start-bridge.sh` (daily start).
- Host tests (no hardware needed) in `desktop/common/tests/`.
