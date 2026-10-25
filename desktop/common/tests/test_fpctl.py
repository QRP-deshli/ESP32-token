#!/usr/bin/env python3
"""Tests fpctl.py against a fake token (pty) that speaks the SP_T_FP admin protocol."""
import os, pty, subprocess, sys, threading, time

here = os.path.dirname(os.path.abspath(__file__))
tool_dir = next(d for d in (os.path.join(here, "..", "bridge"), os.path.join(here, "..")) if os.path.exists(os.path.join(d, "fpctl.py")))
sys.path.insert(0, tool_dir)
import ctaphid_serial_bridge as br

T_FP = 0x30
master, slave = pty.openpty()
os.set_blocking(master, False)
slave_path = os.ttyname(slave)
seen = []
stop = False
state = {"count": 2, "deny": False}

def reply(op, status, a=0, b=0):
    os.write(master, br.encode(T_FP, bytes([op, status, a, b])))

def token():
    dec = br.Decoder()
    os.write(master, b"junk before anything\r\n")
    while not stop:
        try:
            chunk = os.read(master, 512)
        except (BlockingIOError, OSError):
            time.sleep(0.005); continue
        for t, d in dec.feed(chunk):
            if t != T_FP: continue
            seen.append(bytes(d)); op = d[0]
            if op == 1: reply(1, 0, state["count"] >> 8, state["count"] & 0xFF)
            elif op == 2:
                if state["count"] > 0: reply(2, 0x80, 3, 0)            # authorise first
                if state["deny"]: reply(2, 7); continue
                for i in (1, 2, 3):
                    reply(2, 0x80, 1, i)
                    if i < 3: reply(2, 0x80, 2, i)
                reply(2, 0, d[1], d[2])
            elif op == 3: reply(3, 0, d[1], d[2])
            elif op == 4: reply(4, 0x80, 3, 0); reply(4, 0)
            elif op == 5: reply(5, 0x80, 3, 0); reply(5, 0, 0, 3)
threading.Thread(target=token, daemon=True).start()

fails = 0
def run(*args):
    p = subprocess.run([sys.executable, os.path.join(tool_dir, "fpctl.py"), "--port", slave_path, *args],
                       capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout + p.stderr
def check(cond, msg):
    global fails
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: fails += 1

rc, out = run("status");                    check(rc == 0 and "2 fingerprint(s) enrolled" in out, "status shows the count")
rc, out = run("enroll");                    check(rc == 0 and "id 3" in out and "touch 3 of 3" in out and "ALREADY ENROLLED" in out
                                                  and "enrolled as id 3" in out, "enroll picks id count+1, shows authorise + 3 touches")
check(seen[-1] == bytes([2, 0, 3]), "enroll request carried id 3")
rc, out = run("enroll", "--id", "9");       check(rc == 0 and seen[-1] == bytes([2, 0, 9]), "enroll --id 9")
state["deny"] = True
rc, out = run("enroll", "--id", "4");       check(rc == 1 and "denied" in out, "denied authorisation is reported, exit code 1")
state["deny"] = False
rc, out = run("delete", "3");               check(rc == 0 and "deleted id 3" in out and seen[-1] == bytes([3, 0, 3]), "delete 3")
rc, out = run("delete-all", "--yes");       check(rc == 0 and "all fingerprints deleted" in out, "delete-all --yes")
rc, out = run("test");                      check(rc == 0 and "recognised (id 3)" in out, "test reports the matched id")
rc, out = run("enroll", "--id", "5000");    check(rc != 0, "id out of range rejected on the PC side")
stop = True
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
