#!/usr/bin/env python3
"""Drives this OS's setup-token script (desktop/linux, desktop/mac or desktop/windows) through its menu against a fake
token over TCP: enrol, test, delete one, delete all, quit. Typed answers come from stdin."""
import os, shutil, subprocess, sys

from fake_token import FakeToken, Checker

here = os.path.dirname(os.path.abspath(__file__))
desktop = os.path.normpath(os.path.join(here, "..", ".."))
check = Checker()
T_FP = 0x30
state = {"count": 1}
seen = []


def handler(t, d, send):
    if t != T_FP:
        return
    seen.append(d[0])
    reply = lambda st, a=0, b=0: send(T_FP, bytes([d[0], st, a, b]))
    if d[0] == 1:                                       # status
        reply(0, 0, state["count"])
    elif d[0] == 2:                                     # enrol: authorise, three touches
        send(T_FP, bytes([2, 0x80, 3, 0]))
        for i in (1, 2, 3):
            send(T_FP, bytes([2, 0x80, 1, i]))
        state["count"] += 1
        reply(0, d[1], d[2])
    elif d[0] == 3:                                     # delete one
        state["count"] -= 1
        reply(0, d[1], d[2])
    elif d[0] == 4:                                     # delete all
        state["count"] = 0
        reply(0)
    elif d[0] == 5:                                     # test
        reply(0, 0, 1)


if os.name == "nt":
    shell = shutil.which("pwsh") or shutil.which("powershell")
    cmd = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(desktop, "windows", "setup-token.ps1")]
elif sys.platform == "darwin":
    cmd = ["/bin/bash", os.path.join(desktop, "mac", "setup-token.sh")]
else:
    cmd = ["bash", os.path.join(desktop, "linux", "setup-token.sh")]

answers = "\n".join([
    "1", "y",          # enrol another finger (one is enrolled) -> yes
    "2",               # test a finger
    "3", "1", "y",     # delete finger 1, confirm
    "4", "yes",        # delete all (fpctl asks for 'yes')
    "q",               # quit the menu
    "n", "n",          # do not start the bridge / (Windows asks only with a helper)
]) + "\n"
env = dict(os.environ, PICO_TOKEN_PORT=FakeToken(handler).serve_tcp())
p = subprocess.run(cmd, env=env, input=answers, capture_output=True, text=True, timeout=180)
out = p.stdout + p.stderr
print(out)
check("token found on tcp://" in out or "Token on tcp://" in out, "setup-token finds the token")
check("1 finger(s) enrolled" in out, "it shows the enrolled fingers")
check("touch 3 of 3" in out and "now 2 finger(s) enrolled" in out, "menu 1 enrols a finger (three touches)")
check("finger recognised (id 1)" in out, "menu 2 tests a finger")
check("deleted id 1" in out, "menu 3 deletes one finger")
check("all fingerprints deleted" in out, "menu 4 deletes all fingers")
check(2 in seen and 3 in seen and 4 in seen and 5 in seen, f"the token got enrol/delete/delete-all/test requests ({sorted(set(seen))})")
check(p.returncode in (0, 130), f"script ends normally (rc {p.returncode})")
check.finish()
