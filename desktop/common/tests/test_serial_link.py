#!/usr/bin/env python3
"""Port detection of serial_link.py on every OS, without hardware: a fake winreg for Windows, a fake glob for macOS/Linux."""
import fnmatch, sys, types

from fake_token import Checker
import serial_link as sl

check = Checker()

# ---- Windows: COM ports from HARDWARE\DEVICEMAP\SERIALCOMM, Espressif (VID_303A) ones first --------------------------
REG = {
    r"HARDWARE\DEVICEMAP\SERIALCOMM": {"values": [("\\Device\\Serial0", "COM1"), ("\\Device\\USBSER000", "COM12"),
                                        ("\\Device\\USBSER001", "COM3")]},
    r"SYSTEM\CurrentControlSet\Enum\USB": {"keys": ["VID_8087&PID_0026", "VID_303A&PID_1001&MI_00"]},
    r"SYSTEM\CurrentControlSet\Enum\USB\VID_8087&PID_0026": {"keys": ["5&1"]},
    r"SYSTEM\CurrentControlSet\Enum\USB\VID_303A&PID_1001&MI_00": {"keys": ["6&2&0000", "6&3&0000"]},
    r"SYSTEM\CurrentControlSet\Enum\USB\VID_303A&PID_1001&MI_00\6&2&0000\Device Parameters": {"PortName": "COM12"},
    r"SYSTEM\CurrentControlSet\Enum\USB\VID_303A&PID_1001&MI_00\6&3&0000\Device Parameters": {"PortName": "COM7"},  # unplugged
}

class Key:
    def __init__(self, path): self.path = path
    def __enter__(self): return self
    def __exit__(self, *a): pass

def OpenKey(parent, sub):
    path = sub if not isinstance(parent, Key) else parent.path + "\\" + sub
    if path not in REG: raise OSError(path)
    return Key(path)
def EnumValue(k, i):
    v = REG[k.path].get("values", [])
    if i >= len(v): raise OSError
    return (v[i][0], v[i][1], 1)
def EnumKey(k, i):
    v = REG[k.path].get("keys", [])
    if i >= len(v): raise OSError
    return v[i]
def QueryValueEx(k, name):
    if name not in REG[k.path]: raise OSError
    return (REG[k.path][name], 1)

sys.modules["winreg"] = types.SimpleNamespace(HKEY_LOCAL_MACHINE=None, OpenKey=OpenKey, EnumValue=EnumValue,
                                              EnumKey=EnumKey, QueryValueEx=QueryValueEx)
ports = sl._windows_ports()
check(ports == ["COM12", "COM1", "COM3"], f"windows: Espressif port first, unplugged ones skipped, numeric order: {ports}")
del sys.modules["winreg"]

# ---- macOS and Linux names ----------------------------------------------------------------------------------------
FILES = ["/dev/cu.usbmodem2101", "/dev/tty.usbmodem2101", "/dev/cu.usbmodem101", "/dev/cu.Bluetooth-Incoming-Port",
         "/dev/cu.usbserial-110", "/dev/ttyACM1", "/dev/ttyACM0", "/dev/ttyUSB0", "/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit-if00"]
real_glob, real_platform, real_realpath = sl.glob.glob, sl.sys.platform, sl.os.path.realpath
sl.glob.glob = lambda pat: [f for f in FILES if fnmatch.fnmatch(f, pat)]
sl.os.path.realpath = lambda p: "/dev/ttyACM1" if "by-id" in p else p
try:
    sl.sys.platform = "darwin"
    ports = sl._posix_ports()
    check(ports == ["/dev/cu.usbmodem101", "/dev/cu.usbmodem2101", "/dev/cu.usbserial-110"],
          f"macOS: only /dev/cu.*, usbmodem first: {ports}")
    sl.sys.platform = "linux"
    ports = sl._posix_ports()
    check(ports == ["/dev/ttyACM1", "/dev/ttyACM0", "/dev/ttyUSB0"], f"linux: by-id Espressif first, no duplicates: {ports}")
finally:
    sl.glob.glob, sl.sys.platform, sl.os.path.realpath = real_glob, real_platform, real_realpath

check(not sl.probe("tcp://127.0.0.1:1", 115200), "probe of a closed tcp port is False")
check.finish()
