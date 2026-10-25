#!/usr/bin/env bash
# Builds pico-vhid (the virtual FIDO HID helper the bridge uses on macOS) and signs it.
#
#   ./build.sh                                        ad-hoc signature, no entitlement: builds, cannot create the device
#   ./build.sh "Apple Development: ..."               bare binary signed with the entitlement (only enough if macOS
#                                                     accepts it without a profile, see ../virtual-hid.md)
#   ./build.sh "Apple Development: ..." x.provisionprofile
#                                                     PicoVHID.app with the profile embedded (the normal way for a
#                                                     restricted entitlement); pico-vhid becomes a link into the app
#
# Needs the Xcode command line tools (xcode-select --install). Check the result with ./pico-vhid --check.
set -eu
cd "$(dirname "$0")"
identity="${1:-}"
profile="${2:-}"

if [ -n "$profile" ]; then
    [ -n "$identity" ] || { echo "a signing identity is needed with a provisioning profile" >&2; exit 1; }
    [ -f "$profile" ] || { echo "no such file: $profile" >&2; exit 1; }
fi
rm -rf pico-vhid PicoVHID.app
if [ -z "$profile" ]; then
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
    exit 0
fi

# the bundle identifier must match the App ID in the profile: "TEAMID.com.example.picovhid" -> "com.example.picovhid"
plist="$(mktemp)"
security cms -D -i "$profile" >"$plist"
app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist" 2>/dev/null || true)"
team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$plist" 2>/dev/null || true)"
rm -f "$plist"
[ -n "$app_id" ] && [ -n "$team" ] || { echo "cannot read the App ID from $profile" >&2; exit 1; }
bundle_id="${app_id#"$team".}"

mkdir -p PicoVHID.app/Contents/MacOS
swiftc -O -o PicoVHID.app/Contents/MacOS/pico-vhid main.swift
cp "$profile" PicoVHID.app/Contents/embedded.provisionprofile
cat >PicoVHID.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$bundle_id</string>
	<key>CFBundleName</key><string>PicoVHID</string>
	<key>CFBundleExecutable</key><string>pico-vhid</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST
# the entitlements must also carry the team's application identifier for the profile to match
ents="$(mktemp)"
cp pico-vhid.entitlements "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$ents"
codesign --force --sign "$identity" --entitlements "$ents" --options runtime PicoVHID.app
rm -f "$ents"
ln -s PicoVHID.app/Contents/MacOS/pico-vhid pico-vhid
echo "built $(pwd)/PicoVHID.app ($bundle_id, team $team); pico-vhid links into it. Check: ./pico-vhid --check"
