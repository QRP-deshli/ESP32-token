"""
virtual_hid.py - the virtual USB HID FIDO device that browsers and libfido2 see, one backend per operating system.

    hid = open_virtual_hid(helper, log=log)  # the right backend for this OS, or HidUnavailable with the reason
    hid = UhidDevice()                     # Linux, /dev/uhid
    hid = HelperProcessHid([path])         # any OS: a small native helper program owns the device (macOS: desktop/mac/vhid)
    hid.create(name, vid, pid)
    report = hid.poll(timeout)             # an output report from the OS (host -> token), or None
    hid.send_input(report)                 # a 64-byte input report to the OS (token -> host)
    hid.fileno()                           # a selectable file descriptor, or None
    hid.close()

Helper protocol (HelperProcessHid): the bridge starts `helper --name NAME --vid 0xVVVV --pid 0xPPPP`. The helper creates
a HID device with FIDO_REPORT_DESC, then
    - writes every output report it gets from the OS to its stdout, exactly 64 bytes each (no report ID),
    - reads input reports from its stdin, exactly 64 bytes each, and hands them to the OS,
    - writes log lines to stderr, and exits when stdin is closed.
A helper that cannot create the device exits with a non-zero status and an explanation on stderr.
"""
import errno
import os
import queue
import select
import struct
import subprocess
import sys
import threading

from serial_link import LinkClosed

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
REPORT_LEN = 64
UHID_PATH = "/dev/uhid"
MAC_HELPER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mac", "vhid", "pico-vhid"))


class HidUnavailable(Exception):
    """No virtual HID backend can be used here; the message says why and what to do."""


class VirtualHid:
    def __init__(self, log=None):
        self.log = log or (lambda *a: None)

    def create(self, name, vid, pid):
        raise NotImplementedError

    def poll(self, timeout):
        raise NotImplementedError

    def send_input(self, report):
        raise NotImplementedError

    def fileno(self):
        return None

    def close(self):
        pass


# ----------------------------------------------------------------------------
# Linux: uhid (linux/uhid.h)
# ----------------------------------------------------------------------------
UHID_DESTROY, UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT = 1, 2, 3, 4, 5, 6
UHID_GET_REPORT, UHID_GET_REPORT_REPLY = 9, 10
UHID_CREATE2, UHID_INPUT2, UHID_SET_REPORT, UHID_SET_REPORT_REPLY = 11, 12, 13, 14
UHID_DATA_MAX = 4096
UHID_EVENT_SIZE = 4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + UHID_DATA_MAX   # packed struct uhid_event
BUS_USB = 3


class UhidDevice(VirtualHid):
    def __init__(self, path=UHID_PATH, fd=None, log=None):
        super().__init__(log)
        self.fd = fd if fd is not None else os.open(path, os.O_RDWR | os.O_NONBLOCK)

    def fileno(self):
        return self.fd

    def create(self, name, vid, pid):
        ev = struct.pack("<I128s64s64sHHIIII4096s",
                         UHID_CREATE2,
                         name.encode()[:127], b"ctaphid-serial-bridge", b"",
                         len(FIDO_REPORT_DESC), BUS_USB, vid, pid, 0, 0,
                         FIDO_REPORT_DESC)
        assert len(ev) == UHID_EVENT_SIZE
        os.write(self.fd, ev)

    def send_input(self, report):
        ev = struct.pack("<IH4096s", UHID_INPUT2, len(report), report)
        os.write(self.fd, ev.ljust(UHID_EVENT_SIZE, b"\0"))

    def _reply(self, etype, payload):
        os.write(self.fd, (struct.pack("<I", etype) + payload).ljust(UHID_EVENT_SIZE, b"\0"))

    def poll(self, timeout):
        if timeout and not select.select([self.fd], [], [], timeout)[0]:
            return None
        try:
            ev = os.read(self.fd, UHID_EVENT_SIZE)
        except BlockingIOError:
            return None
        if len(ev) < 4:
            return None
        (etype,) = struct.unpack_from("<I", ev, 0)
        if etype == UHID_OUTPUT:
            (size,) = struct.unpack_from("<H", ev, 4 + UHID_DATA_MAX)
            return ev[4:4 + min(size, UHID_DATA_MAX)]
        if etype == UHID_GET_REPORT:
            (rid,) = struct.unpack_from("<I", ev, 4)
            self._reply(UHID_GET_REPORT_REPLY, struct.pack("<IHH", rid, errno.EIO, 0))
        elif etype == UHID_SET_REPORT:
            (rid,) = struct.unpack_from("<I", ev, 4)
            self._reply(UHID_SET_REPORT_REPLY, struct.pack("<IH", rid, errno.EIO))
        elif etype == UHID_START:
            self.log("uhid: started")
        elif etype in (UHID_OPEN, UHID_CLOSE, UHID_STOP):
            self.log("uhid: event", etype)
        return None

    def close(self):
        try:
            self._reply(UHID_DESTROY, b"")
        except OSError:
            pass


# ----------------------------------------------------------------------------
# Any OS: a native helper process owns the device, reports go through its stdin/stdout
# ----------------------------------------------------------------------------
class HelperProcessHid(VirtualHid):
    def __init__(self, cmd, log=None):
        super().__init__(log)
        self.cmd = list(cmd)
        self.proc = None
        self.reports = queue.Queue()

    def create(self, name, vid, pid):
        try:
            self.proc = subprocess.Popen(self.cmd + ["--name", name, "--vid", f"0x{vid:04x}", "--pid", f"0x{pid:04x}"],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        except OSError as e:
            raise OSError(f"cannot start the virtual HID helper {self.cmd[0]}: {e}") from e
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        out = self.proc.stdout
        while True:
            report = b""
            while len(report) < REPORT_LEN:
                chunk = out.read(REPORT_LEN - len(report))
                if not chunk:
                    self.reports.put(None)       # helper gone
                    return
                report += chunk
            self.reports.put(report)

    def poll(self, timeout):
        try:
            report = self.reports.get(timeout=timeout) if timeout else self.reports.get_nowait()
        except queue.Empty:
            return None
        if report is None:
            self.reports.put(None)               # stay closed for later calls
            raise LinkClosed(f"virtual HID helper exited (status {self.proc.wait()})")
        return report

    def send_input(self, report):
        try:
            self.proc.stdin.write(bytes(report))
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as e:
            raise LinkClosed(f"virtual HID helper: {e}") from e

    def close(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                self.proc.kill()


# ----------------------------------------------------------------------------
def open_virtual_hid(helper=None, uhid_path=UHID_PATH, log=None):
    """The virtual HID backend for this OS. `helper` (a program path) overrides the default on every OS."""
    if helper:
        return HelperProcessHid([helper], log)
    if sys.platform.startswith("linux"):
        try:
            return UhidDevice(uhid_path, log=log)
        except OSError as e:
            raise HidUnavailable(f"cannot open {uhid_path}: {e}\n"
                                 "Run as root, or grant access with a udev rule, e.g.\n"
                                 '  KERNEL=="uhid", GROUP="plugdev", MODE="0660"\n'
                                 "and `sudo modprobe uhid` if the node is missing.") from e
    if sys.platform == "darwin":
        if not os.access(MAC_HELPER, os.X_OK):
            raise HidUnavailable(f"the macOS virtual HID helper is not built ({MAC_HELPER}).\n"
                                 "Build it with desktop/mac/vhid/build.sh (see desktop/mac/README.md).")
        return HelperProcessHid([MAC_HELPER], log)
    raise HidUnavailable("this OS has no built-in virtual HID backend. On Windows pass --helper with a virtual HID helper\n"
                         "(see desktop/windows/virtual-hid.md). fpctl.py works without the bridge.")
