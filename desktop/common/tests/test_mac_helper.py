#!/usr/bin/env python3
"""The real macOS helper (desktop/mac/vhid/pico-vhid, built by build.sh) without the HID entitlement, as on any machine
without an Apple provisioning profile: it must start, refuse clearly, and the bridge must stop with that reason."""
import os, subprocess, sys

from fake_token import Checker, FakeToken

check = Checker()
here = os.path.dirname(os.path.abspath(__file__))
helper = os.path.normpath(os.path.join(here, "..", "..", "mac", "vhid", "pico-vhid"))
if sys.platform != "darwin" or not os.access(helper, os.X_OK):
    print("macOS only, and desktop/mac/vhid/build.sh must have run; skipped")
    check.finish()

p = subprocess.run([helper, "--help"], capture_output=True, text=True, timeout=10)
check(p.returncode == 0 and "--check" in p.stdout, "pico-vhid --help runs")

p = subprocess.run([helper, "--check"], capture_output=True, text=True, timeout=10)
if p.returncode == 0:
    print("this machine can create the device (entitlement present): the refusal checks do not apply")
else:
    check(p.returncode == 1 and "com.apple.developer.hid.virtual.device" in p.stderr,
          f"--check without the entitlement exits 1 and names the entitlement (rc {p.returncode})")
    p = subprocess.run([helper, "--vid", "0x1d50"], input=b"", capture_output=True, timeout=10)
    check(p.returncode == 1 and p.stdout == b"", "a refused helper writes nothing on stdout (the report channel)")

    tok = FakeToken(lambda t, d, send: None)
    p = subprocess.run([sys.executable, os.path.join(here, "..", "ctaphid_serial_bridge.py"), "--port", tok.serve_tcp()],
                       capture_output=True, text=True, timeout=30)
    check(p.returncode == 1 and "virtual HID helper exited (status 1)" in p.stderr and "entitlement" in p.stderr,
          "the bridge stops with exit code 1 and passes on the helper's reason")
check.finish()
