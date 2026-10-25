#!/usr/bin/env python3
"""Tests fpctl.py against a fake token that speaks the SP_T_FP admin protocol, over TCP (every OS) and a pty (POSIX)."""
import os, subprocess, sys

from fake_token import FakeToken, Checker, HAVE_PTY

here = os.path.dirname(os.path.abspath(__file__))
tool_dir = os.path.join(here, "..")
T_FP = 0x30
seen = []
state = {"count": 2, "deny": False}

def handler(t, d, send):
    if t != T_FP: return
    seen.append(d); op = d[0]
    reply = lambda op, status, a=0, b=0: send(T_FP, bytes([op, status, a, b]))
    if op == 1: reply(1, 0, state["count"] >> 8, state["count"] & 0xFF)
    elif op == 2:
        if state["count"] > 0: reply(2, 0x80, 3, 0)            # authorise first
        if state["deny"]: reply(2, 7); return
        for i in (1, 2, 3):
            reply(2, 0x80, 1, i)
            if i < 3: reply(2, 0x80, 2, i)
        reply(2, 0, d[1], d[2])
    elif op == 3: reply(3, 0, d[1], d[2])
    elif op == 4: reply(4, 0x80, 3, 0); reply(4, 0)
    elif op == 5: reply(5, 0x80, 3, 0); reply(5, 0, 0, 3)

check = Checker()

def suite(kind, port):
    def run(*args):
        p = subprocess.run([sys.executable, os.path.join(tool_dir, "fpctl.py"), "--port", port, *args],
                           capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout + p.stderr
    c = lambda cond, msg: check(cond, f"[{kind}] {msg}")
    rc, out = run("status");                    c(rc == 0 and "2 fingerprint(s) enrolled" in out, "status shows the count")
    rc, out = run("enroll");                    c(rc == 0 and "id 3" in out and "touch 3 of 3" in out and "ALREADY ENROLLED" in out
                                                  and "enrolled as id 3" in out, "enroll picks id count+1, shows authorise + 3 touches")
    c(seen[-1] == bytes([2, 0, 3]), "enroll request carried id 3")
    rc, out = run("enroll", "--id", "9");       c(rc == 0 and seen[-1] == bytes([2, 0, 9]), "enroll --id 9")
    state["deny"] = True
    rc, out = run("enroll", "--id", "4");       c(rc == 1 and "denied" in out, "denied authorisation is reported, exit code 1")
    state["deny"] = False
    rc, out = run("delete", "3");               c(rc == 0 and "deleted id 3" in out and seen[-1] == bytes([3, 0, 3]), "delete 3")
    rc, out = run("delete-all", "--yes");       c(rc == 0 and "all fingerprints deleted" in out, "delete-all --yes")
    rc, out = run("test");                      c(rc == 0 and "recognised (id 3)" in out, "test reports the matched id")
    rc, out = run("enroll", "--id", "5000");    c(rc != 0, "id out of range rejected on the PC side")

suite("tcp", FakeToken(handler, b"junk before anything\r\n").serve_tcp())
if HAVE_PTY:
    suite("pty", FakeToken(handler, b"junk before anything\r\n").serve_pty())
check.finish()
