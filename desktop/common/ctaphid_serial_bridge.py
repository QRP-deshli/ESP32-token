#!/usr/bin/env python3
"""
ctaphid_serial_bridge.py - expose a Pico FIDO2 token that talks CTAPHID over a
serial port (ESP32-C6 build, USB_TRANSPORT_SERIAL) as a normal USB-HID FIDO
authenticator: on Linux via /dev/uhid, on macOS via the small native helper in
desktop/mac/vhid, on any OS via a helper program given with --helper.

The private keys never leave the token: the bridge only forwards the 64-byte
CTAPHID reports (CTAP2/U2F requests and responses) in both directions.

Usage:
    sudo ./ctaphid_serial_bridge.py                       # Linux, auto-detect the port
    sudo ./ctaphid_serial_bridge.py --port /dev/ttyACM0
    sudo ./ctaphid_serial_bridge.py --port /dev/ttyUSB0 --baud 921600   # plain UART build
    ./ctaphid_serial_bridge.py                            # macOS (uses desktop/mac/vhid/pico-vhid)
    python ctaphid_serial_bridge.py --helper C:\\path\\to\\helper.exe   # Windows, see desktop/windows/virtual-hid.md
    ./ctaphid_serial_bridge.py --list                     # show candidate ports

Standard library only. The OS-specific parts are in serial_link.py (serial port) and virtual_hid.py (virtual device).
"""
import argparse
import os
import select
import sys
import time

from serial_frames import Decoder, encode, T_HID, T_PONG, HID_LEN
from serial_link import list_ports, open_link, probe
from virtual_hid import HelperProcessHid, UhidDevice

HERE = os.path.dirname(os.path.abspath(__file__))
MAC_HELPER = os.path.join(HERE, "..", "mac", "vhid", "pico-vhid")


# ----------------------------------------------------------------------------
# Bridge
# ----------------------------------------------------------------------------
class Bridge:
    """Moves 64-byte reports between a VirtualHid and the token's SerialLink. Knows nothing about the OS."""

    def __init__(self, args, hid):
        self.args = args
        self.hid = hid
        self.ser = None
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
        for p in list_ports():
            if probe(p, self.args.baud):
                return p
        return None

    def connect_serial(self):
        port = self.pick_port()
        if not port:
            return False
        try:
            self.ser = open_link(port, self.args.baud)
        except (OSError, ValueError) as e:
            self.log(f"cannot open {port}: {e}")
            return False
        self.dec = Decoder()
        self.log(f"token on {port}")
        return True

    def drop_serial(self):
        if self.ser is not None:
            self.ser.close()
            self.ser = None
            self.log("serial link lost, waiting for the token to come back")

    # --- OS -> token
    def on_output_report(self, report):
        if len(report) == HID_LEN + 1 and report[0] == 0:
            report = report[1:]            # leading report ID 0 (hidraw writers add it)
        if len(report) != HID_LEN:
            self.vlog(f"ignoring output report of {len(report)} bytes")
            return
        self.vlog("host->token", report[:8].hex(), "...")
        if self.ser is None:
            self.vlog("no token connected, dropping report")
            return
        try:
            self.ser.write(encode(T_HID, report))
            self.to_dev += 1
        except (OSError, TimeoutError):
            self.drop_serial()

    # --- token -> OS
    def on_serial_data(self, chunk):
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
                self.hid.send_input(data)
                self.from_dev += 1
            elif ftype == T_PONG:
                pass

    def read_serial(self, timeout):
        try:
            chunk = self.ser.read(timeout)
        except OSError:
            self.drop_serial()
            return
        if chunk:
            self.on_serial_data(chunk)

    def step(self):
        """One turn of the main loop: wait up to 0.5 s for either side, handle what arrived."""
        fds = [self.hid.fileno()] + ([self.ser.fileno()] if self.ser is not None else [])
        if None not in fds:
            # both sides are selectable file descriptors (Linux, macOS)
            r, _, _ = select.select(fds, [], [], 0.5)
            if fds[0] in r:
                report = self.hid.poll(0)
                if report is not None:
                    self.on_output_report(report)
            if self.ser is not None and self.ser.fileno() in r:
                self.read_serial(0)
            return
        # otherwise poll both with short timeouts (Windows handles, helper pipes)
        if self.ser is None:
            report = self.hid.poll(0.2)
            if report is not None:
                self.on_output_report(report)
            return
        while True:
            report = self.hid.poll(0)
            if report is None:
                break
            self.on_output_report(report)
        if self.ser is not None:
            self.read_serial(0.01)

    def run(self):
        self.hid.create(self.args.name, self.args.vid, self.args.pid)
        self.log(f"virtual FIDO device {self.args.vid:04x}:{self.args.pid:04x} created")
        last_try = 0.0
        while True:
            if self.ser is None and time.monotonic() - last_try > 1.0:
                last_try = time.monotonic()
                self.connect_serial()
            self.step()


def open_hid(args, log):
    """The virtual HID backend for this OS, or an explanation of why there is none."""
    if args.helper:
        return HelperProcessHid([args.helper], log)
    if sys.platform.startswith("linux"):
        try:
            return UhidDevice(args.uhid, log=log)
        except OSError as e:
            raise SystemExit(f"cannot open {args.uhid}: {e}\n"
                             "Run as root, or grant access with a udev rule, e.g.\n"
                             '  KERNEL=="uhid", GROUP="plugdev", MODE="0660"\n'
                             "and `sudo modprobe uhid` if the node is missing.")
    if sys.platform == "darwin":
        if not os.access(MAC_HELPER, os.X_OK):
            raise SystemExit(f"the macOS virtual HID helper is not built ({os.path.normpath(MAC_HELPER)}).\n"
                             "Build it with desktop/mac/vhid/build.sh (see desktop/mac/README.md).")
        return HelperProcessHid([MAC_HELPER], log)
    raise SystemExit("this OS has no built-in virtual HID backend. On Windows pass --helper with a virtual HID helper\n"
                     "(see desktop/windows/virtual-hid.md). fpctl.py works without the bridge.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=os.environ.get("PICO_TOKEN_PORT"),
                    help="serial device (default: $PICO_TOKEN_PORT, else auto-detect by PING)")
    ap.add_argument("--baud", type=int, default=115200,
                    help="only matters for the plain-UART firmware build (default 115200; firmware default is 921600)")
    ap.add_argument("--vid", type=lambda x: int(x, 0), default=0x1D50, help="USB vendor id of the virtual device")
    ap.add_argument("--pid", type=lambda x: int(x, 0), default=0x619B, help="USB product id of the virtual device")
    ap.add_argument("--name", default="Pico FIDO2 (serial bridge)")
    ap.add_argument("--uhid", default="/dev/uhid", help="uhid device node (Linux)")
    ap.add_argument("--helper", default=os.environ.get("PICO_VHID_HELPER"),
                    help="virtual HID helper program (default: $PICO_VHID_HELPER; on macOS desktop/mac/vhid/pico-vhid)")
    ap.add_argument("--list", action="store_true", help="probe candidate ports and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.list:
        for p in list_ports():
            print(p, "-> token" if probe(p, args.baud) else "-> no answer")
        return 0

    bridge = Bridge(args, None)
    bridge.hid = open_hid(args, bridge.vlog)
    try:
        bridge.run()
    except KeyboardInterrupt:
        pass
    except OSError as e:              # includes LinkClosed: the virtual HID helper died
        bridge.log(e)
        return 1
    finally:
        bridge.hid.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
