#!/usr/bin/env bash
# Daily start of the serial bridge: makes your PC see the token as a USB FIDO key.
# Leave this terminal open while you use the token; Ctrl+C stops it.
#   ./start-bridge.sh        normal
#   ./start-bridge.sh -v     also print every packet
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if bridge_running; then
    bad "the bridge is already running (in another terminal?)"
    info "Stop it with Ctrl+C there, or run:  pkill -f ctaphid_serial_bridge.py"
    exit 1
fi

if [ ! -x "$VHID_HELPER" ]; then
    bad "the virtual HID helper is not built: run desktop/mac/vhid/build.sh (see desktop/mac/README.md)"
    exit 1
fi

ok "starting the bridge. Keep this window open; it prints >>> TOUCH THE FINGERPRINT SENSOR NOW <<< when needed."
cd "$BRIDGE_DIR" && exec python3 ./ctaphid_serial_bridge.py "$@"
