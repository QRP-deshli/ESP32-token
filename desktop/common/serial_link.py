"""
serial_link.py - the serial link to the token, with one backend per operating system (standard library only).

    link = open_link(name, baud)      # "/dev/ttyACM0", "/dev/cu.usbmodem101", "COM5", or "tcp://127.0.0.1:7000"
    link.write(data)                  # raises TimeoutError / OSError
    chunk = link.read(timeout)        # b"" when nothing arrived in time, raises LinkClosed when the token is gone
    link.fileno()                     # a selectable file descriptor, or None (Windows)
    link.close()

    list_ports()                      # candidate port names, most likely first
    find_token(baud)                  # the first candidate that answers PING with PONG, or None

Backends: PosixSerial (termios; Linux and macOS), WindowsSerial (ctypes + kernel32), SocketLink (tcp://, used by the
host tests and usable for a token reached over the network). Adding a backend only touches this file.
"""
import errno
import glob
import os
import select
import socket
import struct
import sys
import time

from serial_frames import Decoder, encode, T_PING, T_PONG, PONG_ID

ESPRESSIF_VID = 0x303A      # the C6's USB-Serial/JTAG normally enumerates as 303A:1001


class LinkClosed(OSError):
    """The other end went away (token unplugged, socket closed)."""


class SerialLink:
    name = "?"

    def read(self, timeout):
        raise NotImplementedError

    def write(self, data, timeout=1.0):
        raise NotImplementedError

    def fileno(self):
        return None

    def close(self):
        pass

    def drain(self):
        """Throw away bytes that are already waiting (stale replies)."""
        try:
            while self.read(0.05):
                pass
        except OSError:
            pass


# ----------------------------------------------------------------------------
# POSIX (Linux, macOS): raw termios, no pyserial needed
# ----------------------------------------------------------------------------
class PosixSerial(SerialLink):
    IOSSIOSPEED = 0x80085402      # macOS: _IOW('T', 2, speed_t), sets any baud rate

    def __init__(self, path, baud):
        import termios
        self.name = path
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            attrs = termios.tcgetattr(self.fd)
        except termios.error:
            return                         # not a tty (pty/socket used in tests)
        iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
        cflag = (cflag & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | getattr(termios, "CRTSCTS", 0))) \
            | termios.CS8 | termios.CLOCAL | termios.CREAD
        # macOS has no B460800/B921600 constants; the native USB port ignores the baud rate anyway
        speed = getattr(termios, f"B{baud}", None)
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW,
                          [0, 0, cflag, 0, speed or termios.B115200, speed or termios.B115200, cc])
        if sys.platform == "darwin":
            import fcntl
            if speed is None:
                try:
                    fcntl.ioctl(self.fd, self.IOSSIOSPEED, struct.pack("L", baud))
                except OSError:
                    pass
            # macOS lets several programs open the same port; the bridge and fpctl.py must not share it. TIOCEXCL
            # keeps other programs out (serial monitors), the lock makes our own tools fail fast with "busy".
            try:
                fcntl.ioctl(self.fd, termios.TIOCEXCL)
            except OSError:
                pass
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(self.fd)
                raise OSError(errno.EBUSY, f"{path} is in use (is ctaphid_serial_bridge.py or fpctl.py running?)")
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def fileno(self):
        return self.fd

    def read(self, timeout):
        if timeout and not select.select([self.fd], [], [], timeout)[0]:
            return b""
        try:
            chunk = os.read(self.fd, 512)
        except BlockingIOError:
            return b""
        except OSError as e:               # ENXIO (macOS) / EIO (Linux) once the token is unplugged
            raise LinkClosed(f"{self.name}: {e}") from e
        if not chunk:
            raise LinkClosed(f"{self.name} closed")
        return chunk

    def write(self, data, timeout=1.0):
        deadline = time.monotonic() + timeout
        view = memoryview(data)
        while view:
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise TimeoutError("serial write timeout")
                select.select([], [self.fd], [], 0.05)
            except OSError as e:
                raise LinkClosed(f"{self.name}: {e}") from e

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


def _posix_ports():
    if sys.platform == "darwin":
        # prefer /dev/cu.*: opening /dev/tty.* waits for carrier detect
        return sorted(glob.glob("/dev/cu.usbmodem*")) + \
            sorted(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/cu.wchusbserial*") + glob.glob("/dev/cu.SLAB*"))
    ports = sorted(glob.glob("/dev/serial/by-id/*Espressif*") + glob.glob("/dev/serial/by-id/*USB_JTAG*"))
    out = []
    for p in [os.path.realpath(p) for p in ports] + sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*")):
        if p not in out:          # the by-id patterns can match the same device twice
            out.append(p)
    return out


# ----------------------------------------------------------------------------
# Windows: kernel32 through ctypes
# ----------------------------------------------------------------------------
class WindowsSerial(SerialLink):
    """Synchronous handle with per-call timeouts. The bridge reads and writes from one thread, so no overlapped I/O."""

    def __init__(self, port, baud):
        import ctypes
        from ctypes import wintypes
        self.ct, self.wt = ctypes, wintypes
        self.k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k32.CreateFileW.restype = wintypes.HANDLE
        self.name = port
        path = port if port.startswith("\\\\.\\") else "\\\\.\\" + port     # \\.\COM10 and above need this form
        GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING = 0x80000000, 0x40000000, 3
        h = self.k32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
        if h in (None, wintypes.HANDLE(-1).value):
            raise ctypes.WinError(ctypes.get_last_error())
        self.h = h

        class DCB(ctypes.Structure):
            _fields_ = [("DCBlength", wintypes.DWORD), ("BaudRate", wintypes.DWORD), ("flags", wintypes.DWORD),
                        ("wReserved", wintypes.WORD), ("XonLim", wintypes.WORD), ("XoffLim", wintypes.WORD),
                        ("ByteSize", ctypes.c_ubyte), ("Parity", ctypes.c_ubyte), ("StopBits", ctypes.c_ubyte),
                        ("XonChar", ctypes.c_char), ("XoffChar", ctypes.c_char), ("ErrorChar", ctypes.c_char),
                        ("EofChar", ctypes.c_char), ("EvtChar", ctypes.c_char), ("wReserved1", wintypes.WORD)]

        class COMMTIMEOUTS(ctypes.Structure):
            _fields_ = [(n, wintypes.DWORD) for n in ("ReadIntervalTimeout", "ReadTotalTimeoutMultiplier",
                                                      "ReadTotalTimeoutConstant", "WriteTotalTimeoutMultiplier",
                                                      "WriteTotalTimeoutConstant")]
        self.COMMTIMEOUTS = COMMTIMEOUTS
        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not self.k32.GetCommState(self.h, ctypes.byref(dcb)):
            self._fail()
        dcb.BaudRate = baud
        # fBinary only: no parity check, no flow control, and DTR/RTS left de-asserted (DTR_CONTROL_DISABLE,
        # RTS_CONTROL_DISABLE). The ESP32 USB-Serial/JTAG resets the chip when RTS is asserted while DTR is not, so
        # the bridge must never drive those lines.
        dcb.flags = 0x0001
        dcb.ByteSize, dcb.Parity, dcb.StopBits = 8, 0, 0
        if not self.k32.SetCommState(self.h, ctypes.byref(dcb)):
            self._fail()
        PURGE_RXCLEAR, PURGE_TXCLEAR = 0x0008, 0x0004
        self.k32.PurgeComm(self.h, PURGE_RXCLEAR | PURGE_TXCLEAR)
        self._timeouts = None

    def _fail(self):
        err = self.ct.get_last_error()
        self.close()
        raise self.ct.WinError(err)

    def _set_timeouts(self, read_ms, write_ms):
        if self._timeouts == (read_ms, write_ms):
            return
        MAXDWORD = 0xFFFFFFFF
        t = self.COMMTIMEOUTS()
        if read_ms:
            # return as soon as any byte arrives, or after read_ms with nothing
            t.ReadIntervalTimeout, t.ReadTotalTimeoutMultiplier, t.ReadTotalTimeoutConstant = MAXDWORD, MAXDWORD, read_ms
        else:
            t.ReadIntervalTimeout = MAXDWORD     # return immediately with whatever is buffered
        t.WriteTotalTimeoutConstant = write_ms
        if not self.k32.SetCommTimeouts(self.h, self.ct.byref(t)):
            raise LinkClosed(f"{self.name}: {self.ct.WinError(self.ct.get_last_error())}")
        self._timeouts = (read_ms, write_ms)

    def read(self, timeout):
        self._set_timeouts(max(0, min(int(timeout * 1000), 0xFFFFFFFE)), 1000)
        buf = self.ct.create_string_buffer(512)
        n = self.wt.DWORD(0)
        if not self.k32.ReadFile(self.h, buf, 512, self.ct.byref(n), None):
            raise LinkClosed(f"{self.name}: {self.ct.WinError(self.ct.get_last_error())}")
        return buf.raw[:n.value]

    def write(self, data, timeout=1.0):
        self._set_timeouts(self._timeouts[0] if self._timeouts else 0, max(1, int(timeout * 1000)))
        n = self.wt.DWORD(0)
        if not self.k32.WriteFile(self.h, bytes(data), len(data), self.ct.byref(n), None):
            raise LinkClosed(f"{self.name}: {self.ct.WinError(self.ct.get_last_error())}")
        if n.value != len(data):
            raise TimeoutError("serial write timeout")

    def close(self):
        if getattr(self, "h", None):
            self.k32.CloseHandle(self.h)
            self.h = None


def _windows_ports():
    """COM ports that exist now, Espressif (VID 303A) ones first. Bluetooth serial ports are left out: opening one can
    block for seconds while Windows tries to connect, and the bridge probes every second while the token is away."""
    import winreg
    present = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM") as k:
            i = 0
            while True:
                try:
                    device, port = winreg.EnumValue(k, i)[:2]
                except OSError:
                    break
                if "bth" not in device.lower():          # \Device\BthModem0, ...
                    present.append(port)
                i += 1
    except OSError:
        return []
    espressif = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Enum\USB") as usb:
            for dev in _subkeys(usb):
                if not dev.upper().startswith(f"VID_{ESPRESSIF_VID:04X}"):
                    continue
                with winreg.OpenKey(usb, dev) as dk:
                    for inst in _subkeys(dk):
                        try:
                            with winreg.OpenKey(dk, inst + r"\Device Parameters") as pk:
                                espressif.append(winreg.QueryValueEx(pk, "PortName")[0])
                        except OSError:
                            pass
    except OSError:
        pass

    def com_number(p):
        return int(p[3:]) if p.upper().startswith("COM") and p[3:].isdigit() else 0
    return sorted({p for p in espressif if p in present}, key=com_number) + \
        sorted({p for p in present if p not in espressif}, key=com_number)


def _subkeys(key):
    import winreg
    i = 0
    while True:
        try:
            yield winreg.EnumKey(key, i)
        except OSError:
            return
        i += 1


# ----------------------------------------------------------------------------
# tcp://host:port (host tests, or a token behind a network serial server)
# ----------------------------------------------------------------------------
class SocketLink(SerialLink):
    def __init__(self, url):
        self.name = url
        host, _, port = url[len("tcp://"):].rpartition(":")
        self.sock = socket.create_connection((host or "127.0.0.1", int(port)), timeout=2)
        self.sock.setblocking(False)

    def fileno(self):
        return self.sock.fileno() if os.name != "nt" else None

    def read(self, timeout):
        if not select.select([self.sock], [], [], timeout)[0]:
            return b""
        try:
            chunk = self.sock.recv(512)
        except BlockingIOError:
            return b""
        if not chunk:
            raise LinkClosed(f"{self.name} closed")
        return chunk

    def write(self, data, timeout=1.0):
        self.sock.settimeout(timeout)
        try:
            self.sock.sendall(data)
        except socket.timeout:
            raise TimeoutError("serial write timeout")
        finally:
            self.sock.setblocking(False)

    def close(self):
        self.sock.close()


# ----------------------------------------------------------------------------
def open_link(name, baud):
    if name.startswith("tcp://"):
        return SocketLink(name)
    if os.name == "nt":
        return WindowsSerial(name, baud)
    return PosixSerial(name, baud)


def list_ports():
    return _windows_ports() if os.name == "nt" else _posix_ports()


def probe(name, baud, wait=0.6):
    """True if `name` answers our PING with the expected PONG."""
    try:
        link = open_link(name, baud)
    except (OSError, ValueError):
        return False
    try:
        dec = Decoder()
        link.write(encode(T_PING, b"hi"))
        end = time.monotonic() + wait
        while time.monotonic() < end:
            for t, d in dec.feed(link.read(0.1)):
                if t == T_PONG and d.startswith(PONG_ID):
                    return True
        return False
    except (OSError, TimeoutError):
        return False
    finally:
        link.close()


def find_token(baud):
    for p in list_ports():
        if probe(p, baud):
            return p
    return None
