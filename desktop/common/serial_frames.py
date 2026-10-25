"""
serial_frames.py - the frame protocol spoken over the token's serial port (portable, no OS-specific imports).

Must match pico-keys-sdk/src/usb/serial/serial_proto.h:

    A5 5A | len (u16 LE, = 1 + data) | type (u8) | data | crc16-ccitt (u16 LE, over len+type+data)
"""
import struct

SOF0, SOF1 = 0xA5, 0x5A
T_PING, T_PONG, T_HID, T_CCID, T_FP = 0x01, 0x02, 0x10, 0x20, 0x30
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
