#!/usr/bin/env bash
# Read-only check: is the token there, does the sensor answer, how many fingers are enrolled, is the PC set up?
# Exit code 0 = ready to use, 1 = something is missing.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

problems=0
echo "Pico FIDO2 token check"
echo

# --- the PC side ---
if [ -x "$VHID_HELPER" ]; then
    "$VHID_HELPER" --check >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "virtual HID helper can create the virtual device"
    elif [ "$rc" -ge 128 ]; then
        warn "macOS killed the virtual HID helper (signal $((rc - 128))): its entitlement is not backed by a provisioning profile (desktop/mac/virtual-hid.md)"
        problems=1
    else
        warn "virtual HID helper cannot create the device (no HID entitlement): browsers will not see the token (desktop/mac/virtual-hid.md)"
        problems=1
    fi
else warn "virtual HID helper not built: run desktop/mac/vhid/build.sh (the bridge needs it)"; problems=1; fi

# --- the token side ---
if bridge_running; then
    ok "the bridge is running"
    if need_cmd fido2-token "brew install libfido2"; then
        dev="$(find_hid_device)"
        if [ -n "$dev" ]; then
            ok "virtual FIDO device $dev"
            infoout="$(fido2-token -I "$dev" 2>/dev/null)"
            if [ -n "$infoout" ]; then
                ok "token answers: $(printf '%s\n' "$infoout" | pin_state_from_info)"
            else
                warn "the virtual device exists but the token did not answer (unplugged? restart the bridge)"; problems=1
            fi
        else
            warn "the bridge runs but no virtual FIDO device was found"; problems=1
        fi
    fi
    info "Fingerprints can't be counted while the bridge runs (it uses the same serial port)."
    if [ -t 0 ] && ask_yn "Stop the bridge to count the enrolled fingers?" n; then
        stop_bridge
        ok "bridge stopped (restart it with desktop/mac/start-bridge.sh)"
    else
        echo; echo "Not fully checked (bridge running)."; exit "$problems"
    fi
fi

refresh_state
print_state
[ "$TOKEN_OK" = 1 ] && [ "$SENSOR_OK" = 1 ] || problems=1
if [ "$SENSOR_OK" = 1 ] && [ "$FINGERS" -eq 0 ]; then
    warn "no finger enrolled: the token refuses everything until you run desktop/mac/setup-token.sh"; problems=1
fi
[ "$TOKEN_OK" = 1 ] && info "The token's own keys are created automatically the first time it is used; they can't be read from the PC."

echo
if [ "$problems" -eq 0 ]; then
    echo "Ready. Start the bridge with desktop/mac/start-bridge.sh"
else
    echo "Not ready. desktop/mac/setup-token.sh helps with fingers; see the README troubleshooting table."
fi
exit "$problems"
