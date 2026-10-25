#!/usr/bin/env python3
"""End-to-end test of ctaphid_serial_bridge.py without hardware:
   fake token (pty, speaks the serial frame protocol)  <->  Bridge  <->  fake /dev/uhid (SEQPACKET socketpair)."""
import os, pty, socket, struct, sys, threading, time, types, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bridge", os.path.join(here, "..", "ctaphid_serial_bridge.py"))
br = importlib.util.module_from_spec(spec); spec.loader.exec_module(br)

fails = 0
def check(cond, msg):
    global fails
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: fails += 1

# ---- fake token on a pty ----------------------------------------------------
master, slave = pty.openpty()
slave_path = os.ttyname(slave)
os.set_blocking(master, False)
stop = False
seen_from_host = []

def ctaphid_init_response(req):
    cid_req = req[0:4]; cmd = req[4]; nonce = req[7:15]
    assert cmd == 0x86
    new_cid = bytes([0xDE, 0xAD, 0xBE, 0xEF])
    payload = nonce + new_cid + bytes([2, 1, 0, 0, 0x05])      # proto 2, ver 1.0.0, caps wink+cbor
    resp = cid_req + bytes([0x86, 0, len(payload)]) + payload
    return resp.ljust(64, b"\0")

def fake_token():
    dec = br.Decoder()
    # boot-ROM style noise + a frame with a bad CRC before anything useful
    os.write(master, b"ESP-ROM:esp32c6-20220919\r\nBuild:Sep 19 2022\r\n\xa5\x5a\xff\xff")
    bad = bytearray(br.encode(br.T_HID, bytes(64))); bad[10] ^= 0xFF
    os.write(master, bytes(bad))
    while not stop:
        try:
            chunk = os.read(master, 512)
        except (BlockingIOError, OSError):
            time.sleep(0.005); continue
        for t, d in dec.feed(chunk):
            if t == br.T_PING:
                os.write(master, br.encode(br.T_PONG, br.PONG_ID))
            elif t == br.T_HID:
                seen_from_host.append(d)
                if d[4] == 0x86:
                    os.write(master, br.encode(br.T_HID, ctaphid_init_response(d)))
threading.Thread(target=fake_token, daemon=True).start()

# ---- auto-detect probe -------------------------------------------------------
check(br.probe(slave_path, 115200), "probe(): fake token answers PING with PKSER1")

# ---- bridge with mock uhid ---------------------------------------------------
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
a.setblocking(False); b.settimeout(3)
args = types.SimpleNamespace(port=slave_path, baud=115200, vid=0x1D50, pid=0x619B,
                             name="Pico FIDO2 (serial bridge)", verbose=False)
bridge = br.Bridge(args, a.fileno())
threading.Thread(target=bridge.run, daemon=True).start()

ev = b.recv(br.UHID_EVENT_SIZE)
check(len(ev) == br.UHID_EVENT_SIZE and struct.unpack_from("<I", ev, 0)[0] == br.UHID_CREATE2, "UHID_CREATE2 sent, full-size event")
rd_size, bus, vid, pid = struct.unpack_from("<HHII", ev, 4 + 128 + 64 + 64)
check((bus, vid, pid) == (3, 0x1D50, 0x619B), f"create2 bus/vid/pid = {bus}/{vid:04x}/{pid:04x}")
check(ev[4 + 256 + 20: 4 + 256 + 20 + rd_size] == br.FIDO_REPORT_DESC, "FIDO report descriptor delivered intact")

# ---- host sends CTAPHID_INIT like libfido2 (hidraw write = 0x00 report id + 64 bytes) ----
nonce = bytes(range(1, 9))
init = (b"\xff\xff\xff\xff" + bytes([0x86, 0, 8]) + nonce).ljust(64, b"\0")
out = struct.pack("<I4096sHB", br.UHID_OUTPUT, (b"\x00" + init).ljust(4096, b"\0"), 65, 1).ljust(br.UHID_EVENT_SIZE, b"\0")
b.send(out)

resp = None
deadline = time.time() + 3
while time.time() < deadline:
    try:
        ev = b.recv(br.UHID_EVENT_SIZE)
    except socket.timeout:
        break
    if struct.unpack_from("<I", ev, 0)[0] == br.UHID_INPUT2:
        (size,) = struct.unpack_from("<H", ev, 4)
        resp = ev[6:6 + size]; break

check(len(seen_from_host) == 1 and seen_from_host[0] == init, "token received the 64-byte request (report id stripped)")
check(resp is not None and len(resp) == 64, "UHID_INPUT2 carries a 64-byte response")
if resp:
    check(resp[4] == 0x86 and resp[7:15] == nonce and resp[15:19] == bytes.fromhex("deadbeef"), "CTAPHID_INIT response nonce + new CID correct")
# inject line noise + a corrupted frame *while the bridge is connected*, then do another round trip
crc_before = bridge.dec.crc_errors
bad = bytearray(br.encode(br.T_HID, bytes(64))); bad[10] ^= 0xFF
os.write(master, b"I (123) noise\r\n\xa5\x5a\xff\xff" + bytes(bad))
b.send(out)
resp2 = None
deadline = time.time() + 3
while time.time() < deadline:
    try:
        ev = b.recv(br.UHID_EVENT_SIZE)
    except socket.timeout:
        break
    if struct.unpack_from("<I", ev, 0)[0] == br.UHID_INPUT2:
        (size,) = struct.unpack_from("<H", ev, 4)
        resp2 = ev[6:6 + size]; break
check(bridge.dec.crc_errors > crc_before, f"corrupted frame rejected by the bridge ({bridge.dec.crc_errors - crc_before} CRC error counted)")
check(resp2 is not None and resp2[4] == 0x86, "valid response after noise still delivered (resync works)")

# 64-byte output without report id (other writers) also accepted
b.send(struct.pack("<I4096sHB", br.UHID_OUTPUT, init.ljust(4096, b"\0"), 64, 1).ljust(br.UHID_EVENT_SIZE, b"\0"))
time.sleep(0.3)
check(len(seen_from_host) == 3, "unnumbered 64-byte output report accepted too")

stop = True
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
