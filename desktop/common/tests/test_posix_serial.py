#!/usr/bin/env python3
"""PosixSerial (serial_link.py) on a pty, Linux and macOS: raw mode, every baud rate the bridge accepts (macOS has no
B460800/B921600), unplug turns into LinkClosed, and on macOS a second open of the same port is refused."""
import os, sys

from fake_token import Checker, HAVE_PTY
import serial_link as sl

check = Checker()
if not HAVE_PTY:
    print("no pty on this OS, skipped")
    check.finish()

import pty, termios

for baud in (115200, 230400, 460800, 921600):
    m, s = pty.openpty()
    try:
        link = sl.PosixSerial(os.ttyname(s), baud)
        attrs = termios.tcgetattr(link.fd)
        raw = attrs[0] == 0 and attrs[1] == 0 and attrs[3] == 0 and attrs[6][termios.VMIN] == 0
        check(raw and attrs[2] & termios.CLOCAL, f"{baud} baud: opens in raw mode with CLOCAL")
        link.close()
    except Exception as e:
        check(False, f"{baud} baud: {e!r}")
    os.close(s); os.close(m)

m, s = pty.openpty()
path = os.ttyname(s)
link = sl.PosixSerial(path, 115200)
os.write(m, b"\xa5\x5a")
check(link.read(0.5) == b"\xa5\x5a", "read returns the bytes the token sent")
check(link.read(0.1) == b"", "read times out with b\"\"")

if sys.platform == "darwin":
    try:
        sl.PosixSerial(path, 115200).close()
        check(False, "macOS: second open of the same port is refused")
    except OSError as e:
        check("in use" in str(e), f"macOS: second open of the same port is refused ({e})")
    link.close()
    try:
        sl.PosixSerial(path, 115200).close()
        check(True, "macOS: the port can be opened again after close()")
    except OSError as e:
        check(False, f"macOS: the port can be opened again after close() ({e})")
    link = sl.PosixSerial(path, 115200)

os.close(s); os.close(m)                  # the token disappears
try:
    for _ in range(5):
        link.read(0.2)
    check(False, "unplug raises LinkClosed")
except sl.LinkClosed:
    check(True, "unplug raises LinkClosed (the bridge then waits for the token)")
link.close()
check.finish()
