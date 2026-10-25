#!/usr/bin/env python3
"""
fpctl.py - manage the fingerprints of a Pico FIDO2 token that has the Waveshare UART fingerprint sensor
(firmware built with -DENABLE_FINGERPRINT=ON).

    ./fpctl.py status                 sensor present? how many fingerprints are enrolled?
    ./fpctl.py enroll [--id N]        add a fingerprint (three touches); first one needs no authorisation
    ./fpctl.py delete ID              remove one fingerprint
    ./fpctl.py delete-all [--yes]     remove all fingerprints
    ./fpctl.py test                   check that a finger is recognised (nothing is changed)

Once at least one finger is enrolled, enrol/delete first ask you to touch the sensor with an ENROLLED finger.
Stop ctaphid_serial_bridge.py first: both programs need the token's serial port. Linux, macOS and Windows; stdlib only.
"""
import argparse
import os
import sys
import time

from serial_frames import Decoder, encode, T_FP
from serial_link import find_token, open_link

OP_STATUS, OP_ENROLL, OP_DELETE, OP_DELETE_ALL, OP_TEST = 1, 2, 3, 4, 5
PROGRESS = 0x80
STEP_PLACE, STEP_LIFT, STEP_AUTH = 1, 2, 3

STATUS_TEXT = {
    0: "ok",
    1: "failed (poor image, or the three touches were different fingers - try again)",
    2: "the fingerprint sensor does not answer (check wiring, power and the RST pin)",
    3: "timed out: no finger touched the sensor",
    4: "the sensor's fingerprint memory is full",
    5: "already enrolled: this finger, or that ID, is already in use (try another --id)",
    6: "finger not recognised",
    7: "denied: authorisation with an enrolled finger failed",
    8: "bad request",
    9: "the sensor is busy, try again",
}


def say_progress(op, step, arg):
    if step == STEP_PLACE:
        print(f"  place your finger on the sensor (touch {arg} of 3) ...", flush=True)
    elif step == STEP_LIFT:
        print("  lift your finger ...", flush=True)
    elif step == STEP_AUTH:
        if op == OP_TEST:
            print("  touch the sensor ...", flush=True)
        else:
            print("  touch the sensor with an ALREADY ENROLLED finger to authorise ...", flush=True)


def request(link, req, timeout=120.0):
    """Send one admin request and collect frames until the final reply. Returns (status, a, b)."""
    dec = Decoder()
    link.drain()           # so an old reply is not mistaken for ours
    link.write(encode(T_FP, bytes(req)))
    op = req[0]
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        for ftype, data in dec.feed(link.read(0.2)):
            if ftype != T_FP or len(data) != 4 or data[0] != op:
                continue
            status, a, b = data[1], data[2], data[3]
            if status == PROGRESS:
                say_progress(op, a, b)
                continue
            return status, a, b
    raise TimeoutError("no answer from the token")


def open_token(args):
    port = args.port or find_token(args.baud)
    if not port:
        sys.exit("no token found (is it plugged in on the native USB port, and is ctaphid_serial_bridge.py stopped?)")
    try:
        return open_link(port, args.baud), port
    except OSError as e:
        sys.exit(f"cannot open {port}: {e} (is ctaphid_serial_bridge.py running?)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=os.environ.get("PICO_TOKEN_PORT"),
                    help="serial device (default: $PICO_TOKEN_PORT, else auto-detect)")
    ap.add_argument("--baud", type=int, default=115200)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    e = sub.add_parser("enroll")
    e.add_argument("--id", type=int, help="user id 1..4095 (default: number enrolled + 1)")
    d = sub.add_parser("delete")
    d.add_argument("id", type=int)
    da = sub.add_parser("delete-all")
    da.add_argument("--yes", action="store_true")
    sub.add_parser("test")
    args = ap.parse_args()

    link, port = open_token(args)
    print(f"token on {port}")
    try:
        if args.cmd == "status":
            st, a, b = request(link, [OP_STATUS], 10)
            if st == 0:
                print(f"sensor OK, {(a << 8) | b} fingerprint(s) enrolled")
            else:
                print(STATUS_TEXT.get(st, f"status {st}"))
            return 0 if st == 0 else 1

        if args.cmd == "enroll":
            uid = args.id
            if uid is None:
                st, a, b = request(link, [OP_STATUS], 10)
                if st != 0:
                    print(STATUS_TEXT.get(st, f"status {st}"))
                    return 1
                uid = ((a << 8) | b) + 1
            if not 1 <= uid <= 0xFFF:
                sys.exit("id must be 1..4095")
            print(f"enrolling fingerprint as id {uid}")
            st, a, b = request(link, [OP_ENROLL, uid >> 8, uid & 0xFF])
            print(("enrolled as id %d" % uid) if st == 0 else STATUS_TEXT.get(st, f"status {st}"))
            return 0 if st == 0 else 1

        if args.cmd == "delete":
            if not 1 <= args.id <= 0xFFF:
                sys.exit("id must be 1..4095")
            st, a, b = request(link, [OP_DELETE, args.id >> 8, args.id & 0xFF])
            print(("deleted id %d" % args.id) if st == 0 else STATUS_TEXT.get(st, f"status {st}"))
            return 0 if st == 0 else 1

        if args.cmd == "delete-all":
            if not args.yes and input("Delete ALL fingerprints? type 'yes': ").strip() != "yes":
                print("cancelled")
                return 1
            st, a, b = request(link, [OP_DELETE_ALL])
            print("all fingerprints deleted" if st == 0 else STATUS_TEXT.get(st, f"status {st}"))
            return 0 if st == 0 else 1

        if args.cmd == "test":
            st, a, b = request(link, [OP_TEST])
            print(("finger recognised (id %d)" % ((a << 8) | b)) if st == 0 else STATUS_TEXT.get(st, f"status {st}"))
            return 0 if st == 0 else 1
    except TimeoutError as ex:
        print(f"{ex} - is the firmware built with -DENABLE_FINGERPRINT=ON, and is the bridge stopped?")
        return 1
    except OSError as ex:
        print(f"lost the token: {ex}")
        return 1
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
