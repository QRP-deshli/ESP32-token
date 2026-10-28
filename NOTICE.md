# Credits and licenses

This project is a port of **pico-fido2** to the ESP32-C6, plus a serial transport, a fingerprint gate and bug fixes
(see `CHANGES.md`).

## Where this project comes from

- **LibreKeys pico-fido2** (https://github.com/librekeys/pico-fido2) is the repository this port started from and its
  main inspiration. Some functions are taken from it, unchanged or adapted for the ESP32-C6. What was changed or
  added is listed in `CHANGES.md`.
- **Pico FIDO / Pico Keys** by Pol Henarejos (https://github.com/polhenarejos/pico-fido2) is the author of the code in
  those upstream files: the notice "Copyright (c) 2022 Pol Henarejos" stays at the top of every file taken from there.

Modified upstream files and the date of the changes are described in `CHANGES.md` (AGPL-3.0, section 5).

## Parts and licenses

| Part | Origin | License |
|---|---|---|
| `pico-fido/`, `pico-keys-sdk/`, `pico-openpgp/`, `src/fido2/` | LibreKeys pico-fido2 (https://github.com/librekeys/pico-fido2); code by Pol Henarejos | AGPL-3.0 (see the `LICENSE` file in each folder) |
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
