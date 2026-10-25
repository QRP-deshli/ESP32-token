#!/usr/bin/env bash
# Interactive setup for the Pico FIDO2 token. It first shows what the token already has (fingers enrolled), then lets
# you enrol more fingers, test or delete them, initialise the token's keys, or start over with a new token identity,
# and finally offers to start the bridge.
#
#   ./setup-token.sh
#
# Run it with the token plugged into the NATIVE USB port. It stops a running bridge (the bridge and fpctl.py need the
# same serial port) and asks for your sudo password once.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

trap cleanup_bridge EXIT
trap 'echo; exit 130' INT TERM

need_fido_tools() { need_cmd fido2-token "sudo apt install fido2-tools"; }

show_state() {
    refresh_state
    print_state
}

# ---------------------------------------------------------------------------------------------------------------------
enroll_flow() {
    refresh_state
    if [ "$TOKEN_OK" = 0 ] || [ "$SENSOR_OK" = 0 ]; then print_state; return; fi
    if [ "$FINGERS" -gt 0 ]; then
        info "$FINGERS finger(s) are already enrolled. To add one you first touch the sensor with an ENROLLED finger."
        ask_yn "Enrol another finger?" n || return
    else
        info "No finger is enrolled yet. The first one needs no authorisation. Three touches, lifting in between."
    fi
    local rc id
    (cd "$BRIDGE_DIR" && python3 ./fpctl.py enroll); rc=$?
    if [ "$rc" -ne 0 ]; then
        info "If it says the ID is already in use (after deleting fingers the numbers have gaps), pick a free ID."
        if ask_yn "Try again with a specific ID (1..4095)?" n; then
            read -r -p "ID: " id || return
            case "$id" in ''|*[!0-9]*) bad "not a number"; return ;; esac
            (cd "$BRIDGE_DIR" && python3 ./fpctl.py enroll --id "$id"); rc=$?
        fi
    fi
    refresh_state
    if [ "$rc" -eq 0 ]; then
        ok "now $FINGERS finger(s) enrolled"
        [ "$FINGERS" -eq 1 ] && info "Tip: enrol a second finger as a backup (menu option 1 again)."
    fi
}

test_flow() {
    refresh_state
    if [ "$SENSOR_OK" = 0 ]; then print_state; return; fi
    (cd "$BRIDGE_DIR" && python3 ./fpctl.py test)
}

delete_one_flow() {
    refresh_state
    if [ "$SENSOR_OK" = 0 ]; then print_state; return; fi
    if [ "$FINGERS" -eq 0 ]; then info "No fingers enrolled."; return; fi
    info "Fingers are numbered in the order you enrolled them (1, 2, ...). You must authorise with an enrolled finger."
    local id
    read -r -p "ID to delete (1..$FINGERS): " id || return
    case "$id" in ''|*[!0-9]*) bad "not a number"; return ;; esac
    if [ "$FINGERS" -eq 1 ]; then
        warn "This is your only finger: afterwards the token refuses everything until you enrol a new one."
    fi
    ask_yn "Delete finger $id?" n || return
    (cd "$BRIDGE_DIR" && python3 ./fpctl.py delete "$id")
    refresh_state; info "$FINGERS finger(s) left."
}

delete_all_flow() {
    refresh_state
    if [ "$SENSOR_OK" = 0 ]; then print_state; return; fi
    if [ "$FINGERS" -eq 0 ]; then info "No fingers enrolled."; return; fi
    warn "This removes ALL $FINGERS fingerprint(s). The token will refuse everything until you enrol again."
    (cd "$BRIDGE_DIR" && python3 ./fpctl.py delete-all)   # asks you to type 'yes' itself
    refresh_state; info "$FINGERS finger(s) left."
}

# Run the bridge in the background, wait for it to find the token. Leaves BRIDGE_STARTED_BY_US=1 on success.
bridge_up() {
    start_bridge_bg
    if ! wait_conn_gt 0 10; then
        bad "the bridge could not reach the token (see $BRIDGE_LOG)"
        stop_bridge
        return 1
    fi
}

init_keys_flow() {
    need_fido_tools || return
    info "This sends the token its first FIDO message. On a brand-new token that is the moment it creates its keys"
    info "(the ESP32 monitor shows 'KEY DEVICE is empty. Generating...'). On a token that has them nothing changes."
    ask_yn "Go ahead?" y || return
    bridge_up || return
    local dev out
    dev="$(wait_hid 10)" || { bad "no virtual FIDO device appeared"; stop_bridge; return; }
    out="$(sudo fido2-token -I "$dev" 2>&1)"
    if printf '%s\n' "$out" | grep -q '^proto:'; then
        ok "the token answered ($dev): $(printf '%s\n' "$out" | pin_state_from_info)"
    else
        bad "the token did not answer: $(printf '%s\n' "$out" | tail -n1)"
    fi
    stop_bridge
}

reset_flow() {
    need_fido_tools || return
    echo
    warn "NEW TOKEN IDENTITY (FIDO reset)"
    info "This erases every account registered on the token and its PIN, and creates a new device key."
    info "Websites where you used it will no longer recognise it. Your FINGERPRINTS are not touched."
    info "The token only accepts a reset in the first 10 seconds after it is powered up, and it asks for a finger."
    local ans
    read -r -p "Type RESET to continue: " ans || return
    [ "$ans" = RESET ] || { info "cancelled"; return; }

    bridge_up || return
    local base dev rc
    base="$(token_conn_count)"
    echo
    echo "Now UNPLUG the token's USB cable, plug it back in, wait about 3 seconds, then press Enter."
    read -r _ || { stop_bridge; return; }
    if ! wait_conn_gt "$base" 8; then
        bad "the bridge did not see the token come back"; stop_bridge; return
    fi
    dev="$(wait_hid 5)" || { bad "no virtual FIDO device appeared"; stop_bridge; return; }
    echo "Touch the sensor with an ENROLLED finger now ..."
    sudo fido2-token -R "$dev"; rc=$?
    stop_bridge
    if [ "$rc" -eq 0 ]; then
        ok "reset done: the token has a new identity. Set a new PIN when a website asks."
    else
        bad "the reset failed. If it says NOT_ALLOWED the 10-second window had passed: choose this option again."
    fi
}

# ---------------------------------------------------------------------------------------------------------------------
start_bridge_now() {
    exec "$SCRIPTS_DIR/start-bridge.sh"
}

main_menu() {
    local choice
    while true; do
        echo
        refresh_state
        if [ "$TOKEN_OK" = 1 ] && [ "$SENSOR_OK" = 1 ]; then
            echo "Token on $TOKEN_PORT, $FINGERS finger(s) enrolled."
        else
            print_state
        fi
        cat <<'MENU'

What do you want to do?
  1) Enrol a finger (the first one, or another one)
  2) Test a finger
  3) Delete one finger
  4) Delete ALL fingers
  5) Initialise the token's keys (safe to repeat)
  6) Create a NEW token identity (erases all registered accounts and the PIN)
  7) Start the bridge and use the token
  q) Quit
MENU
        read -r -p "Choice: " choice || break
        case "$choice" in
            1) enroll_flow ;;
            2) test_flow ;;
            3) delete_one_flow ;;
            4) delete_all_flow ;;
            5) init_keys_flow ;;
            6) reset_flow ;;
            7) start_bridge_now ;;
            q|Q|"") break ;;
            *) warn "unknown choice" ;;
        esac
    done
    echo
    if ask_yn "Start the bridge now?" y; then start_bridge_now; fi
}

# --- main -------------------------------------------------------------------------------------------------------------
echo "Pico FIDO2 token setup"
echo
need_cmd python3 || exit 1
[ -f "$BRIDGE_DIR/fpctl.py" ] || { bad "cannot find $BRIDGE_DIR/fpctl.py"; exit 1; }
prepare_system

if bridge_running; then
    warn "The bridge is running and blocks the token's serial port."
    if ask_yn "Stop it now?" y; then stop_bridge; ok "bridge stopped"; else bad "cannot continue while it runs"; exit 1; fi
fi

show_state
if [ "$TOKEN_OK" = 1 ] && [ "$SENSOR_OK" = 1 ] && [ "$FINGERS" -eq 0 ]; then
    echo
    info "No finger is enrolled yet, so the token would refuse everything."
    ask_yn "Enrol your first finger now?" y && enroll_flow
fi
main_menu
