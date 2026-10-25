# Credits and licenses

This project is a port of **pico-fido2** by Pol Henarejos (https://github.com/polhenarejos/pico-fido2) to the
ESP32-C6, plus a serial transport, a fingerprint gate and bug fixes (see `CHANGES.md`).

| Part | Origin | License |
|---|---|---|
| `pico-fido/`, `pico-keys-sdk/`, `pico-openpgp/`, `src/fido2/` | Pol Henarejos, https://github.com/polhenarejos | AGPL-3.0 (see the `LICENSE` file in each folder) |
| `pico-keys-sdk/src/usb/serial/`, `pico-keys-sdk/src/fingerprint/`, `desktop/` | this project | AGPL-3.0, as a derivative work |
| `pico-keys-sdk/tinycbor/` | Intel Corporation | MIT |
| `pico-keys-sdk/mlkem/` | mlkem-native authors | Apache-2.0 OR ISC OR MIT |
| ESP-IDF (not included, you install it) | Espressif | Apache-2.0 |
| `zorxx/neopixel` (downloaded by the ESP-IDF component manager on first build) | zorxx | see its own license |

Because the firmware is derived from AGPL-3.0 code, this repository as a whole is distributed under the
**GNU Affero General Public License v3** (top-level `LICENSE`). Note: some upstream source headers say "GPL version 3";
the `LICENSE` files that ship with the code say AGPLv3, and that is what applies here.

The fingerprint sensor, the ESP32-C6 and Waveshare are trademarks of their owners; this project is not affiliated
with them or with the upstream authors.
