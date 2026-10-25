#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Sourced by them, not run directly.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(dirname "$SCRIPTS_DIR")"
BRIDGE_DIR="${PICO_BRIDGE_DIR:-$DESKTOP_DIR/common}"   # ctaphid_serial_bridge.py, fpctl.py
BRIDGE_PATTERN='^([^ ]*/)?python[0-9.]* +([^ ]*/)?ctaphid_serial_bridge\.py( |$)'   # anchored: only a real bridge process
BRIDGE_LOG="${TMPDIR:-/tmp}/pico-fido2-bridge.log"
UDEV_RULE=/etc/udev/rules.d/70-pico-fido2.rules
BRIDGE_STARTED_BY_US=0

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_BAD=""; C_OFF=""
fi
ok()   { printf '%s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
info() { printf '       %s\n' "$*"; }

# ask_yn "question" y|n   -> returns 0 for yes. End of input counts as "no".
ask_yn() {
    local prompt="$1" def="${2:-n}" ans hint
    if [ "$def" = y ]; then hint='[Y/n]'; else hint='[y/N]'; fi
    read -r -p "$prompt $hint " ans || return 1
    ans="${ans:-$def}"
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { bad "'$1' is not installed${2:+ ($2)}"; return 1; }
}

need_sudo() {
    sudo -v || { bad "sudo is needed (serial port, uhid, ModemManager)"; return 1; }
}

# Things the token needs on the PC: no ModemManager grabbing the serial port, the uhid module for the virtual device.
prepare_system() {
    need_sudo || exit 1
    sudo systemctl stop ModemManager >/dev/null 2>&1 || true
    sudo modprobe uhid >/dev/null 2>&1 || warn "could not load the uhid kernel module (the bridge needs it)"
}

bridge_running() { pgrep -f "$BRIDGE_PATTERN" >/dev/null 2>&1; }

stop_bridge() {
    sudo pkill -f "$BRIDGE_PATTERN" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6; do bridge_running || break; sleep 0.5; done
    BRIDGE_STARTED_BY_US=0
}

# Stop the bridge only if one of our own functions started it (used as an exit trap).
cleanup_bridge() { [ "$BRIDGE_STARTED_BY_US" = 1 ] && stop_bridge; return 0; }

# Start the bridge in the background, logging to $BRIDGE_LOG. Needs sudo to be authenticated already.
start_bridge_bg() {
    : >"$BRIDGE_LOG"
    if command -v setsid >/dev/null 2>&1; then
        ( cd "$BRIDGE_DIR" && setsid sudo ./ctaphid_serial_bridge.py >>"$BRIDGE_LOG" 2>&1 </dev/null & )
    else
        ( cd "$BRIDGE_DIR" && sudo ./ctaphid_serial_bridge.py >>"$BRIDGE_LOG" 2>&1 </dev/null & )
    fi
    BRIDGE_STARTED_BY_US=1
}

# number of times the bridge has connected to the token since it was started
token_conn_count() { local n; n=$(grep -c 'token on' "$BRIDGE_LOG" 2>/dev/null); echo "${n:-0}"; }

# wait_conn_gt BASELINE SECONDS : wait until the connection count is higher than BASELINE
wait_conn_gt() {
    local base="$1" secs="$2" i n
    for ((i = 0; i < secs * 2; i++)); do
        n=$(token_conn_count)
        [ "$n" -gt "$base" ] && return 0
        sleep 0.5
    done
    return 1
}

# print the /dev/hidrawN of the virtual FIDO device, if any (tries without sudo first)
find_hid_device() {
    local dev
    dev=$(fido2-token -L 2>/dev/null | grep -i 'product=0x619b' | head -n1 | cut -d: -f1)
    [ -z "$dev" ] && dev=$(sudo fido2-token -L 2>/dev/null | grep -i 'product=0x619b' | head -n1 | cut -d: -f1)
    [ -n "$dev" ] && echo "$dev"
}

# wait_hid SECONDS : prints the device path once it appears
wait_hid() {
    local secs="${1:-10}" i dev
    for ((i = 0; i < secs * 2; i++)); do
        dev=$(find_hid_device) && [ -n "$dev" ] && { echo "$dev"; return 0; }
        sleep 0.5
    done
    return 1
}

# say whether a PIN is set, from "fido2-token -I" output on stdin
pin_state_from_info() {
    local opts
    opts=$(grep '^options:' | head -n1)
    case "$opts" in
        *noclientPin*) echo "no PIN set yet" ;;
        *clientPin*)   echo "a PIN is set" ;;
        *)             echo "PIN state unknown" ;;
    esac
}

# --- fingerprint state, read with fpctl.py (needs the bridge to be STOPPED: same serial port) -------------------------
TOKEN_OK=0; SENSOR_OK=0; FINGERS=0; TOKEN_PORT=""; FP_OUT=""

refresh_state() {
    local rc
    FP_OUT="$(cd "$BRIDGE_DIR" && python3 ./fpctl.py status 2>&1)"; rc=$?
    TOKEN_OK=0; SENSOR_OK=0; FINGERS=0
    TOKEN_PORT="$(printf '%s\n' "$FP_OUT" | sed -n 's/^token on \(.*\)$/\1/p' | head -n1)"
    [ -n "$TOKEN_PORT" ] && TOKEN_OK=1
    if [ "$rc" -eq 0 ]; then
        SENSOR_OK=1
        FINGERS="$(printf '%s\n' "$FP_OUT" | sed -n 's/^sensor OK, \([0-9]*\) fingerprint.*/\1/p' | head -n1)"
        FINGERS="${FINGERS:-0}"
    fi
    return "$rc"
}

print_state() {
    local msg
    if [ "$TOKEN_OK" = 0 ]; then
        bad "no token found"
        info "Plug the cable into the NATIVE USB port of the ESP32-C6, wait 3 seconds, and make sure the bridge is not running."
        return
    fi
    ok "token found on $TOKEN_PORT"
    if [ "$SENSOR_OK" = 0 ]; then
        msg="$(printf '%s\n' "$FP_OUT" | grep -v '^token on' | tail -n1)"
        bad "fingerprint sensor: ${msg:-no answer}"
    else
        ok "fingerprint sensor answers, $FINGERS finger(s) enrolled"
    fi
}
