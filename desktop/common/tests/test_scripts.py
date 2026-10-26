#!/usr/bin/env python3
"""Runs this OS's check-token script (desktop/linux, desktop/mac or desktop/windows) against a fake token over TCP."""
import os, subprocess, sys

from fake_token import FakeToken, Checker

here = os.path.dirname(os.path.abspath(__file__))
desktop = os.path.normpath(os.path.join(here, "..", ".."))
check = Checker()

def handler(t, d, send):
    if t == 0x30 and d[0] == 1:
        send(0x30, bytes([1, 0, 0, 2]))           # status: sensor OK, 2 fingers

if os.name == "nt":
    cmd = ["cmd.exe", "/d", "/c", os.path.join(desktop, "windows", "check-token.cmd")]
elif sys.platform == "darwin":
    cmd = ["/bin/bash", os.path.join(desktop, "mac", "check-token.sh")]          # the system bash 3.2
else:
    cmd = ["bash", os.path.join(desktop, "linux", "check-token.sh")]

env = dict(os.environ, PICO_TOKEN_PORT=FakeToken(handler).serve_tcp())
p = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
out = p.stdout + p.stderr
print(out)
check("token found on tcp://127.0.0.1:" in out, "check-token finds the token")
check("fingerprint sensor answers, 2 finger(s) enrolled" in out, "check-token reports the sensor and the finger count")
check(p.returncode in (0, 1), f"exit code is 0 or 1 (got {p.returncode})")
check.finish()
