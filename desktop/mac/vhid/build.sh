#!/usr/bin/env bash
# Builds pico-vhid (the virtual FIDO HID helper the bridge uses on macOS) and signs it.
#
#   ./build.sh                            # ad-hoc signature, no entitlement: builds, but cannot create the device
#   ./build.sh "Apple Development: ..."   # sign with your identity and the entitlement (see ../virtual-hid.md)
#
# Needs the Xcode command line tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"
identity="${1:-}"

swiftc -O -o pico-vhid main.swift
if [ -z "$identity" ]; then
    # macOS kills (SIGKILL) an ad-hoc signed binary that claims a restricted entitlement, so leave it out: the helper
    # then starts and explains that the entitlement is missing.
    codesign --force --sign - pico-vhid
    echo "built $(pwd)/pico-vhid, ad-hoc signed WITHOUT com.apple.developer.hid.virtual.device (see ../virtual-hid.md)"
else
    codesign --force --sign "$identity" --entitlements pico-vhid.entitlements --options runtime pico-vhid
    echo "built $(pwd)/pico-vhid, signed by $identity with com.apple.developer.hid.virtual.device"
fi
