#!/usr/bin/env python3
"""WindowsSerial (serial_link.py) against a fake kernel32, so it runs on every OS: the \\\\.\\COMn path, the DCB (no
DTR/RTS, which would reset the ESP32), the per-call timeouts, and unplug errors turning into LinkClosed."""
import ctypes

from fake_token import Checker
import serial_link as sl

check = Checker()
MAXDWORD = 0xFFFFFFFF
INVALID = ctypes.c_void_p(-1).value


class Fn:
    """A kernel32 function stand-in that, like a ctypes function, accepts .restype/.argtypes."""
    def __init__(self, f): self.f = f
    def __call__(self, *a): return self.f(*a)


class FakeKernel32:
    def __init__(self):
        for name in ("CreateFileW", "GetCommState", "SetCommState", "PurgeComm", "SetCommTimeouts", "ReadFile",
                     "WriteFile", "CloseHandle"):
            setattr(self, name, Fn(getattr(self, name)))
        self.opened = None
        self.dcb = None
        self.timeouts = []
        self.rx = []                    # chunks ReadFile hands out
        self.tx = b""
        self.unplugged = False
        self.closed = False
        self.handle = 0x1234

    def CreateFileW(self, path, access, share, sec, disposition, flags, template):
        self.opened = (path, access, share, disposition)
        return self.handle

    def GetCommState(self, h, pdcb):
        dcb = pdcb._obj
        dcb.flags = 0x0001 | (1 << 4) | (1 << 12)     # what Windows may hand back: DTR and RTS enabled
        dcb.BaudRate = 9600
        return 1

    def SetCommState(self, h, pdcb):
        d = pdcb._obj
        self.dcb = dict(BaudRate=d.BaudRate, flags=d.flags, ByteSize=d.ByteSize, Parity=d.Parity, StopBits=d.StopBits)
        return 1

    def PurgeComm(self, h, flags):
        return 1

    def SetCommTimeouts(self, h, pt):
        t = pt._obj
        self.timeouts.append((t.ReadIntervalTimeout, t.ReadTotalTimeoutMultiplier, t.ReadTotalTimeoutConstant,
                              t.WriteTotalTimeoutMultiplier, t.WriteTotalTimeoutConstant))
        return 1

    def ReadFile(self, h, buf, size, pn, overlapped):
        if self.unplugged:
            return 0
        data = self.rx.pop(0) if self.rx else b""
        ctypes.memmove(buf, data, len(data))
        pn._obj.value = len(data)
        return 1

    def WriteFile(self, h, data, size, pn, overlapped):
        if self.unplugged:
            return 0
        self.tx += data[:size]
        pn._obj.value = size
        return 1

    def CloseHandle(self, h):
        self.closed = True
        return 1


k32 = FakeKernel32()
# ctypes has no WinDLL / WinError / get_last_error outside Windows: provide them for the test
saved = {n: getattr(ctypes, n, None) for n in ("WinDLL", "WinError", "get_last_error")}
ctypes.WinDLL = lambda name, use_last_error=False: k32
ctypes.WinError = lambda code=None: OSError(code or 0, "fake Windows error")
ctypes.get_last_error = lambda: 22
try:
    s = sl.WindowsSerial("COM12", 115200)
    check(k32.opened[0] == "\\\\.\\COM12", f"COM12 opened as \\\\.\\COM12 ({k32.opened[0]})")
    check(k32.opened[2] == 0, "opened exclusively (share mode 0)")
    check(k32.dcb["flags"] == 0x0001, f"DCB: fBinary only, DTR_CONTROL_DISABLE and RTS_CONTROL_DISABLE (flags=0x{k32.dcb['flags']:04x})")
    check((k32.dcb["BaudRate"], k32.dcb["ByteSize"], k32.dcb["Parity"], k32.dcb["StopBits"]) == (115200, 8, 0, 0), "115200 8N1")

    k32.rx = [b"\xa5\x5a"]
    check(s.read(0.2) == b"\xa5\x5a", "read returns what ReadFile delivered")
    check(k32.timeouts[-1][:3] == (MAXDWORD, MAXDWORD, 200), "read(0.2): return on the first byte, or after 200 ms")
    check(s.read(0.2) == b"", "read times out with b\"\"")
    n = len(k32.timeouts)
    s.read(0.2)
    check(len(k32.timeouts) == n, "unchanged timeouts are not set again")
    s.read(0)
    check(k32.timeouts[-1][:3] == (MAXDWORD, 0, 0), "read(0): return immediately with what is buffered")

    s.write(b"hello", timeout=0.5)
    check(k32.tx == b"hello" and k32.timeouts[-1][4] == 500, "write sends the bytes with a 500 ms write timeout")

    k32.unplugged = True
    try:
        s.read(0.1); check(False, "unplugged read raises LinkClosed")
    except sl.LinkClosed:
        check(True, "unplugged read raises LinkClosed (the bridge then reconnects)")
    try:
        s.write(b"x"); check(False, "unplugged write raises LinkClosed")
    except sl.LinkClosed:
        check(True, "unplugged write raises LinkClosed")
    s.close()
    check(k32.closed, "close() closes the handle")

    k32.handle = INVALID
    try:
        sl.WindowsSerial("COM3", 115200); check(False, "a port that cannot be opened raises OSError")
    except OSError:
        check(True, "a port that cannot be opened raises OSError")
finally:
    for n, v in saved.items():
        if v is None:
            delattr(ctypes, n)
        else:
            setattr(ctypes, n, v)
check.finish()
