#!/usr/bin/env python3
"""End-to-end test of ctaphid_serial_bridge.py without hardware:
   fake token (TCP on every OS, pty on POSIX)  <->  Bridge  <->  a virtual HID backend:
     - an in-memory fake (every OS, exercises the polling main loop used on Windows),
     - HelperProcessHid with a fake helper program (every OS, the macOS/Windows backend),
     - UhidDevice on a fake /dev/uhid made from a SEQPACKET socketpair (Linux),
     - NullHid (--no-hid): serial side only, unplug/replug recovery."""
import os, queue, socket, struct, sys, tempfile, threading, time, types

from fake_token import FakeToken, Checker, HAVE_PTY
import ctaphid_serial_bridge as br
from serial_frames import encode, T_HID
from serial_link import probe
from virtual_hid import VirtualHid, HelperProcessHid, NullHid, UhidDevice, FIDO_REPORT_DESC
import virtual_hid as vh

check = Checker()
NONCE = bytes(range(1, 9))
INIT = (b"\xff\xff\xff\xff" + bytes([0x86, 0, 8]) + NONCE).ljust(64, b"\0")
BAD = bytearray(encode(T_HID, bytes(64))); BAD[10] ^= 0xFF
NOISE = b"ESP-ROM:esp32c6-20220919\r\nBuild:Sep 19 2022\r\n\xa5\x5a\xff\xff" + bytes(BAD)


def new_token():
    seen = []
    def handler(t, d, send):
        if t == T_HID:
            seen.append(d)
            if d[4] == 0x86:
                cid, nonce = d[0:4], d[7:15]
                payload = nonce + bytes.fromhex("deadbeef") + bytes([2, 1, 0, 0, 0x05])  # proto 2, ver 1.0.0, wink+cbor
                send(T_HID, (cid + bytes([0x86, 0, len(payload)]) + payload).ljust(64, b"\0"))
    return FakeToken(handler, NOISE), seen


def is_init_reply(r):
    return r is not None and len(r) == 64 and r[4] == 0x86 and r[7:15] == NONCE and r[15:19] == bytes.fromhex("deadbeef")


def start_bridge(port, hid):
    args = types.SimpleNamespace(port=port, baud=115200, vid=0x1D50, pid=0x619B,
                                 name="Pico FIDO2 (serial bridge)", verbose=False)
    bridge = br.Bridge(args, hid)
    threading.Thread(target=bridge.run, daemon=True).start()
    return bridge


def wait_until(cond, secs=3):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


# ---- 1. in-memory virtual HID, both transports --------------------------------------------------------------------
class FakeHid(VirtualHid):
    def __init__(self):
        super().__init__()
        self.to_bridge, self.from_bridge, self.created = queue.Queue(), queue.Queue(), None
    def create(self, name, vid, pid): self.created = (name, vid, pid)
    def poll(self, timeout):
        try: return self.to_bridge.get(timeout=timeout) if timeout else self.to_bridge.get_nowait()
        except queue.Empty: return None
    def send_input(self, report): self.from_bridge.put(bytes(report))
    def reply(self):
        try: return self.from_bridge.get(timeout=3)
        except queue.Empty: return None

transports = [("tcp", "serve_tcp")] + ([("pty", "serve_pty")] if HAVE_PTY else [])
for kind, serve in transports:
    c = lambda cond, msg: check(cond, f"[{kind}] {msg}")
    tok, seen = new_token()
    port = getattr(tok, serve)()
    c(probe(port, 115200), "probe(): fake token answers PING with PKSER1")
    hid = FakeHid()
    bridge = start_bridge(port, hid)
    c(wait_until(lambda: bridge.ser is not None), "bridge connects to the token")
    c(hid.created == ("Pico FIDO2 (serial bridge)", 0x1D50, 0x619B), "virtual device created with name/vid/pid")
    hid.to_bridge.put(b"\x00" + INIT)                      # like a hidraw write: report ID 0 + 64 bytes
    resp = hid.reply()
    c(len(seen) == 1 and seen[0] == INIT, "token received the 64-byte request (report id stripped)")
    c(is_init_reply(resp), "CTAPHID_INIT response nonce + new CID correct")
    crc_before = bridge.dec.crc_errors
    tok.inject(b"I (123) noise\r\n" + NOISE)
    hid.to_bridge.put(INIT)                                # 64 bytes without report ID (other writers)
    resp2 = hid.reply()
    c(bridge.dec.crc_errors > crc_before, "corrupted frame rejected by the bridge (CRC error counted)")
    c(is_init_reply(resp2), "valid response after noise still delivered (resync works), unnumbered report accepted")
    hid.to_bridge.put(bytes(10))
    time.sleep(0.2)
    c(len(seen) == 2, "short output report ignored")
    tok.stop = True

# ---- 2. helper-process backend with a fake helper ------------------------------------------------------------------
tmp = tempfile.mkdtemp()
got_path = os.path.join(tmp, "got.bin")
helper = os.path.join(tmp, "fake_helper.py")
with open(helper, "w") as f:
    f.write(f"""import sys
args = sys.argv[1:]
open({got_path!r} + ".args", "w").write(" ".join(args))
sys.stdout.buffer.write({INIT!r}); sys.stdout.buffer.flush()       # the OS sends CTAPHID_INIT
data = sys.stdin.buffer.read(64)                                      # the reply from the token
open({got_path!r}, "wb").write(data)
sys.stdin.buffer.read()                                               # wait for EOF, as a real helper does
""")
tok, seen = new_token()
hid = HelperProcessHid([sys.executable, helper])
bridge = start_bridge(tok.serve_tcp(), hid)
check(wait_until(lambda: os.path.exists(got_path) and os.path.getsize(got_path) == 64),
      "[helper] report from the helper reached the token and the reply came back on the helper's stdin")
check(open(got_path + ".args").read() == "--name Pico FIDO2 (serial bridge) --vid 0x1d50 --pid 0x619b",
      "[helper] helper started with --name/--vid/--pid")
check(os.path.exists(got_path) and is_init_reply(open(got_path, "rb").read()), "[helper] reply is the INIT response")
hid.close()
check(hid.proc.poll() is not None, "[helper] closing stdin stops the helper")
try:
    hid.poll(1); check(False, "[helper] dead helper reported")
except OSError:
    check(True, "[helper] dead helper reported as LinkClosed")
tok.stop = True

# ---- 2b. --no-hid: serial side only, the token is unplugged and comes back -------------------------------------------
tok, seen = new_token()
logs = []
args = types.SimpleNamespace(port=tok.serve_tcp(), baud=115200, vid=0x1D50, pid=0x619B, name="x", verbose=False)
bridge = br.Bridge(args, NullHid())
bridge.log = lambda *a: logs.append(" ".join(map(str, a)))
threading.Thread(target=bridge.run, daemon=True).start()
check(wait_until(lambda: any(l.startswith("token on tcp://") for l in logs)), "[no-hid] bridge logs 'token on ...' without a virtual device")
check(any("--no-hid" in l for l in logs), "[no-hid] bridge says it runs without a virtual device")
tok.unplug()
check(wait_until(lambda: any("serial link lost" in l for l in logs)), "[no-hid] unplug detected ('serial link lost')")
check(wait_until(lambda: sum(l.startswith("token on") for l in logs) == 2, 5), "[no-hid] token found again after replug")
tok.stop = True

# ---- 3. Linux uhid backend on a fake /dev/uhid ---------------------------------------------------------------------
if sys.platform.startswith("linux"):
    tok, seen = new_token()
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    a.setblocking(False); b.settimeout(3)
    bridge = start_bridge(tok.serve_pty(), UhidDevice(fd=a.fileno()))
    ev = b.recv(vh.UHID_EVENT_SIZE)
    check(len(ev) == vh.UHID_EVENT_SIZE and struct.unpack_from("<I", ev, 0)[0] == vh.UHID_CREATE2, "[uhid] UHID_CREATE2 sent, full-size event")
    rd_size, bus, vid, pid = struct.unpack_from("<HHII", ev, 4 + 128 + 64 + 64)
    check((bus, vid, pid) == (3, 0x1D50, 0x619B), f"[uhid] create2 bus/vid/pid = {bus}/{vid:04x}/{pid:04x}")
    check(ev[4 + 256 + 20: 4 + 256 + 20 + rd_size] == FIDO_REPORT_DESC, "[uhid] FIDO report descriptor delivered intact")
    wait_until(lambda: bridge.ser is not None)
    b.send(struct.pack("<I4096sHB", vh.UHID_OUTPUT, (b"\x00" + INIT).ljust(4096, b"\0"), 65, 1).ljust(vh.UHID_EVENT_SIZE, b"\0"))
    resp = None
    end = time.time() + 3
    while time.time() < end and resp is None:
        try: ev = b.recv(vh.UHID_EVENT_SIZE)
        except socket.timeout: break
        if struct.unpack_from("<I", ev, 0)[0] == vh.UHID_INPUT2:
            (size,) = struct.unpack_from("<H", ev, 4); resp = ev[6:6 + size]
    check(is_init_reply(resp), "[uhid] UHID_OUTPUT -> token -> UHID_INPUT2 round trip")
    tok.stop = True

check.finish()
