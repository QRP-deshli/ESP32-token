#!/usr/bin/env python3
"""fpctl.py while the bridge runs (control.py), on every OS: fpctl status/enroll go through the bridge's control port,
CTAPHID traffic keeps flowing during an enrolment, a second admin client is refused, and without a token fpctl fails
fast instead of waiting."""
import os, queue, socket, subprocess, sys, threading, time, types

from fake_token import FakeToken, Checker
import ctaphid_serial_bridge as br
from control import ControlServer
from serial_frames import encode, T_FP, T_HID
from virtual_hid import VirtualHid

check = Checker()
here = os.path.dirname(os.path.abspath(__file__))
INIT = (b"\xff\xff\xff\xff" + bytes([0x86, 0, 8]) + bytes(range(1, 9))).ljust(64, b"\0")
hid_answers_during_enrol = []
enrolling = threading.Event()


def handler(t, d, send):
    if t == T_HID and d[4] == 0x86:
        if enrolling.is_set():
            hid_answers_during_enrol.append(1)
        send(T_HID, (d[0:4] + bytes([0x86, 0, 17]) + d[7:15] + bytes.fromhex("deadbeef") + bytes(5)).ljust(64, b"\0"))
    elif t == T_FP and d[0] == 1:
        send(T_FP, bytes([1, 0, 0, 2]))
    elif t == T_FP and d[0] == 2:                       # a slow enrolment: three touches, half a second apart
        def enrol():                                    # on its own thread, so the token keeps reading meanwhile
            enrolling.set()
            for i in (1, 2, 3):
                send(T_FP, bytes([2, 0x80, 1, i]))
                time.sleep(0.5)
            enrolling.clear()
            send(T_FP, bytes([2, 0, d[1], d[2]]))
        threading.Thread(target=enrol, daemon=True).start()


class FakeHid(VirtualHid):
    def __init__(self):
        super().__init__()
        self.q, self.out = queue.Queue(), queue.Queue()
    def create(self, *a): pass
    def poll(self, timeout):
        try: return self.q.get(timeout=timeout) if timeout else self.q.get_nowait()
        except queue.Empty: return None
    def send_input(self, r): self.out.put(bytes(r))


tok = FakeToken(handler)
hid = FakeHid()
args = types.SimpleNamespace(port=tok.serve_tcp(), baud=115200, vid=0x1D50, pid=0x619B, name="x", verbose=False)
bridge = br.Bridge(args, hid)
bridge.control = ControlServer(port=0)
threading.Thread(target=bridge.run, daemon=True).start()
end = time.time() + 3
while bridge.ser is None and time.time() < end:
    time.sleep(0.02)

env = {k: v for k, v in os.environ.items() if k != "PICO_TOKEN_PORT"}
env["PICO_CONTROL_PORT"] = str(bridge.control.port)
fpctl = [sys.executable, os.path.join(here, "..", "fpctl.py")]

p = subprocess.run(fpctl + ["status"], env=env, capture_output=True, text=True, timeout=30)
check(p.returncode == 0 and "through the running bridge" in p.stdout and "sensor OK, 2 fingerprint(s) enrolled" in p.stdout,
      "fpctl status works while the bridge runs (through its control port)")

enrol = subprocess.Popen(fpctl + ["enroll", "--id", "3"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
enrolling.wait(5)
hid.q.put(INIT)                                         # a browser talks to the token during the enrolment
try:
    resp = hid.out.get(timeout=3)
except queue.Empty:
    resp = None
check(resp is not None and resp[4] == 0x86, "CTAPHID traffic still flows while an enrolment is in progress")
check(hid_answers_during_enrol == [1], "the token saw the CTAPHID request during the enrolment")

second = socket.create_connection(("127.0.0.1", bridge.control.port), timeout=2)
second.settimeout(2)
try:
    refused = second.recv(1) == b""
except OSError:
    refused = True
check(refused, "a second admin client is refused while one is connected")
second.close()

out, _ = enrol.communicate(timeout=30)
check(enrol.returncode == 0 and "touch 3 of 3" in out and "enrolled as id 3" in out, "fpctl enroll works while the bridge runs")

tok.unplug()
end = time.time() + 3
while bridge.ser is not None and time.time() < end:
    time.sleep(0.02)
tok.stop = True
t0 = time.time()
p = subprocess.run(fpctl + ["status"], env=env, capture_output=True, text=True, timeout=30)
check(p.returncode != 0 and time.time() - t0 < 8, f"without a token fpctl fails fast through the bridge ({time.time() - t0:.1f} s)")
check.finish()
