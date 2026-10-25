#!/usr/bin/env python3
"""
ctaphid_serial_bridge.py - expose a Pico FIDO2 token that talks CTAPHID over a
serial port (ESP32-C6 build, USB_TRANSPORT_SERIAL) as a normal USB-HID FIDO
authenticator on Linux, via /dev/uhid.

The private keys never leave the token: the bridge only forwards the 64-byte
CTAPHID reports (CTAP2/U2F requests and responses) in both directions.

Usage:
    sudo ./ctaphid_serial_bridge.py                       # auto-detect the port
    sudo ./ctaphid_serial_bridge.py --port /dev/ttyACM0
    sudo ./ctaphid_serial_bridge.py --port /dev/ttyUSB0 --baud 921600   # plain UART build
    ./ctaphid_serial_bridge.py --list                     # show candidate ports

Standard library only (termios/select/struct). Linux only.
"""
import argparse
import errno
import glob
import os
import select
import struct
import sys
import termios
import time

# ----------------------------------------------------------------------------
# Frame protocol (must match pico-keys-sdk/src/usb/serial/serial_proto.h)
# ----------------------------------------------------------------------------
SOF0, SOF1 = 0xA5, 0x5A
T_PING, T_PONG, T_HID, T_CCID = 0x01, 0x02, 0x10, 0x20
HID_LEN = 64
MAX_DATA = 80
PONG_ID = b"PKSER1"


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(ftype, data=b""):
    if len(data) > MAX_DATA:
        raise ValueError("frame too large")
    body = struct.pack("<H", 1 + len(data)) + bytes([ftype]) + data
    return bytes([SOF0, SOF1]) + body + struct.pack("<H", crc16(body))


class Decoder:
    """Streaming decoder, resynchronises on SOF + CRC like the firmware's one."""

    def __init__(self):
        self.buf = bytearray()
        self.crc_errors = 0

    def feed(self, chunk):
        """Returns a list of (type, data) frames found in the stream so far."""
        self.buf += chunk
        out = []
        while True:
            i = self.buf.find(bytes([SOF0, SOF1]))
            if i < 0:
                # keep a trailing SOF0 in case the SOF1 arrives in the next chunk
                self.buf = self.buf[-1:] if self.buf[-1:] == bytes([SOF0]) else bytearray()
                return out
            if i:
                del self.buf[:i]
            if len(self.buf) < 4:
                return out
            (flen,) = struct.unpack_from("<H", self.buf, 2)
            if flen < 1 or flen > 1 + MAX_DATA:
                del self.buf[:1]          # bogus header, look for the next SOF
                continue
            total = 2 + 2 + flen + 2
            if len(self.buf) < total:
                return out
            body = bytes(self.buf[2:4 + flen])
            (crc,) = struct.unpack_from("<H", self.buf, 4 + flen)
            if crc16(body) == crc:
                out.append((body[2], body[3:]))
                del self.buf[:total]
            else:
                self.crc_errors += 1
                del self.buf[:1]


# ----------------------------------------------------------------------------
# Serial port (raw termios, no pyserial needed)
# ----------------------------------------------------------------------------
BAUDS = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
         57600: termios.B57600, 115200: termios.B115200, 230400: termios.B230400,
         460800: termios.B460800, 921600: termios.B921600}


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
    except termios.error:
        return fd                      # not a tty (pty/socket used in tests)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = (cflag & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.CRTSCTS)) \
        | termios.CS8 | termios.CLOCAL | termios.CREAD
    speed = BAUDS.get(baud, termios.B115200)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def write_all(fd, data, timeout=1.0):
    deadline = time.monotonic() + timeout
    view = memoryview(data)
    while view:
        try:
            n = os.write(fd, view)
            view = view[n:]
        except BlockingIOError:
            if time.monotonic() > deadline:
                raise TimeoutError("serial write timeout")
            select.select([], [fd], [], 0.05)


def probe(path, baud, wait=0.6):
    """True if `path` answers our PING with the expected PONG."""
    try:
        fd = open_serial(path, baud)
    except OSError:
        return False
    try:
        dec = Decoder()
        write_all(fd, encode(T_PING, b"hi"))
        end = time.monotonic() + wait
        while time.monotonic() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(fd, 256)
                except BlockingIOError:
                    continue
                for t, d in dec.feed(chunk):
                    if t == T_PONG and d.startswith(PONG_ID):
                        return True
        return False
    except OSError:
        return False
    finally:
        os.close(fd)


def candidate_ports():
    ports = sorted(glob.glob("/dev/serial/by-id/*Espressif*") + glob.glob("/dev/serial/by-id/*USB_JTAG*"))
    out = []
    for p in [os.path.realpath(p) for p in ports] + sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*")):
        if p not in out:          # the by-id patterns can match the same device twice
            out.append(p)
    return out


# ----------------------------------------------------------------------------
# uhid (linux/uhid.h)
# ----------------------------------------------------------------------------
UHID_DESTROY, UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT = 1, 2, 3, 4, 5, 6
UHID_GET_REPORT, UHID_GET_REPORT_REPLY = 9, 10
UHID_CREATE2, UHID_INPUT2, UHID_SET_REPORT, UHID_SET_REPORT_REPLY = 11, 12, 13, 14
UHID_DATA_MAX = 4096
UHID_EVENT_SIZE = 4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + UHID_DATA_MAX   # packed struct uhid_event
BUS_USB = 3

# Standard FIDO HID report descriptor: usage page 0xF1D0, 64 byte in/out reports, no report ID.
FIDO_REPORT_DESC = bytes([
    0x06, 0xD0, 0xF1,        # Usage Page (FIDO Alliance)
    0x09, 0x01,              # Usage (U2F/CTAP HID Authenticator Device)
    0xA1, 0x01,              # Collection (Application)
    0x09, 0x20,              #   Usage (Input Report Data)
    0x15, 0x00,              #   Logical Minimum (0)
    0x26, 0xFF, 0x00,        #   Logical Maximum (255)
    0x75, 0x08,              #   Report Size (8)
    0x95, 0x40,              #   Report Count (64)
    0x81, 0x02,              #   Input (Data,Var,Abs)
    0x09, 0x21,              #   Usage (Output Report Data)
    0x15, 0x00,
    0x26, 0xFF, 0x00,
    0x75, 0x08,
    0x95, 0x40,
    0x91, 0x02,              #   Output (Data,Var,Abs)
    0xC0,                    # End Collection
])


def uhid_create2(fd, name, vid, pid):
    ev = struct.pack("<I128s64s64sHHIIII4096s",
                     UHID_CREATE2,
                     name.encode()[:127], b"ctaphid-serial-bridge", b"",
                     len(FIDO_REPORT_DESC), BUS_USB, vid, pid, 0, 0,
                     FIDO_REPORT_DESC)
    assert len(ev) == UHID_EVENT_SIZE
    os.write(fd, ev)


def uhid_input(fd, report):
    ev = struct.pack("<IH4096s", UHID_INPUT2, len(report), report)
    os.write(fd, ev.ljust(UHID_EVENT_SIZE, b"\0"))


def uhid_reply(fd, etype, payload):
    os.write(fd, (struct.pack("<I", etype) + payload).ljust(UHID_EVENT_SIZE, b"\0"))


# ----------------------------------------------------------------------------
# Bridge
# ----------------------------------------------------------------------------
class Bridge:
    def __init__(self, args, uhid_fd=None):
        self.args = args
        self.uhid_fd = uhid_fd
        self.ser_fd = None
        self.dec = Decoder()
        self.to_dev = 0
        self.from_dev = 0
        self.verbose = args.verbose
        self.last_touch_keepalive = 0.0

    def log(self, *a):
        print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)

    def vlog(self, *a):
        if self.verbose:
            self.log(*a)

    def pick_port(self):
        if self.args.port:
            return self.args.port
        for p in candidate_ports():
            if probe(p, self.args.baud):
                return p
        return None

    def connect_serial(self):
        port = self.pick_port()
        if not port:
            return False
        try:
            self.ser_fd = open_serial(port, self.args.baud)
        except OSError as e:
            self.log(f"cannot open {port}: {e}")
            return False
        self.dec = Decoder()
        self.log(f"token on {port}")
        return True

    def drop_serial(self):
        if self.ser_fd is not None:
            try:
                os.close(self.ser_fd)
            except OSError:
                pass
            self.ser_fd = None
            self.log("serial link lost, waiting for the token to come back")

    # --- uhid -> serial
    def on_uhid_event(self):
        try:
            ev = os.read(self.uhid_fd, UHID_EVENT_SIZE)
        except BlockingIOError:
            return
        if len(ev) < 4:
            return
        (etype,) = struct.unpack_from("<I", ev, 0)
        if etype == UHID_OUTPUT:
            data = ev[4:4 + UHID_DATA_MAX]
            (size,) = struct.unpack_from("<H", ev, 4 + UHID_DATA_MAX)
            report = data[:size]
            if len(report) == HID_LEN + 1 and report[0] == 0:
                report = report[1:]            # leading report ID 0 (hidraw writers add it)
            if len(report) != HID_LEN:
                self.vlog(f"ignoring output report of {len(report)} bytes")
                return
            self.vlog("host->token", report[:8].hex(), "...")
            if self.ser_fd is None:
                self.vlog("no token connected, dropping report")
                return
            try:
                write_all(self.ser_fd, encode(T_HID, report))
                self.to_dev += 1
            except (OSError, TimeoutError):
                self.drop_serial()
        elif etype == UHID_GET_REPORT:
            (rid,) = struct.unpack_from("<I", ev, 4)
            uhid_reply(self.uhid_fd, UHID_GET_REPORT_REPLY, struct.pack("<IHH", rid, errno.EIO, 0))
        elif etype == UHID_SET_REPORT:
            (rid,) = struct.unpack_from("<I", ev, 4)
            uhid_reply(self.uhid_fd, UHID_SET_REPORT_REPLY, struct.pack("<IH", rid, errno.EIO))
        elif etype == UHID_START:
            self.vlog("uhid: started")
        elif etype in (UHID_OPEN, UHID_CLOSE, UHID_STOP):
            self.vlog("uhid: event", etype)

    # --- serial -> uhid
    def on_serial_readable(self):
        try:
            chunk = os.read(self.ser_fd, 512)
        except BlockingIOError:
            return
        except OSError:
            self.drop_serial()
            return
        if not chunk:
            self.drop_serial()
            return
        for ftype, data in self.dec.feed(chunk):
            if ftype == T_HID and len(data) == HID_LEN:
                self.vlog("token->host", data[:8].hex(), "...")
                # CTAPHID_KEEPALIVE (0x3B|0x80) with status 2 = "user presence needed": tell the person what to do,
                # once per wait (keepalives repeat about every 100 ms; a gap of >1 s means a new wait)
                if data[4] == 0xBB and data[7] == 2:
                    now = time.monotonic()
                    if now - self.last_touch_keepalive > 1.0:
                        self.log(">>> TOUCH THE FINGERPRINT SENSOR NOW <<<")
                    self.last_touch_keepalive = now
                uhid_input(self.uhid_fd, data)
                self.from_dev += 1
            elif ftype == T_PONG:
                pass

    def run(self):
        uhid_create2(self.uhid_fd, self.args.name, self.args.vid, self.args.pid)
        self.log(f"virtual FIDO device {self.args.vid:04x}:{self.args.pid:04x} created")
        last_try = 0.0
        while True:
            if self.ser_fd is None and time.monotonic() - last_try > 1.0:
                last_try = time.monotonic()
                self.connect_serial()
            rl = [self.uhid_fd] + ([self.ser_fd] if self.ser_fd is not None else [])
            r, _, _ = select.select(rl, [], [], 0.5)
            if self.uhid_fd in r:
                self.on_uhid_event()
            if self.ser_fd is not None and self.ser_fd in r:
                self.on_serial_readable()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial device (default: auto-detect by PING)")
    ap.add_argument("--baud", type=int, default=115200,
                    help="only matters for the plain-UART firmware build (default 115200; firmware default is 921600)")
    ap.add_argument("--vid", type=lambda x: int(x, 0), default=0x1D50, help="USB vendor id of the virtual device")
    ap.add_argument("--pid", type=lambda x: int(x, 0), default=0x619B, help="USB product id of the virtual device")
    ap.add_argument("--name", default="Pico FIDO2 (serial bridge)")
    ap.add_argument("--uhid", default="/dev/uhid", help="uhid device node")
    ap.add_argument("--list", action="store_true", help="probe candidate ports and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.list:
        for p in candidate_ports():
            print(p, "-> token" if probe(p, args.baud) else "-> no answer")
        return 0

    try:
        fd = os.open(args.uhid, os.O_RDWR | os.O_NONBLOCK)
    except OSError as e:
        print(f"cannot open {args.uhid}: {e}\n"
              "Run as root, or grant access with a udev rule, e.g.\n"
              '  KERNEL=="uhid", GROUP="plugdev", MODE="0660"\n'
              "and `sudo modprobe uhid` if the node is missing.", file=sys.stderr)
        return 1
    try:
        Bridge(args, fd).run()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            uhid_reply(fd, UHID_DESTROY, b"")
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
