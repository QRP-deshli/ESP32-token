"""
control.py - the bridge's local control endpoint, so fpctl.py works while the bridge owns the token's serial port.

The bridge listens on 127.0.0.1:CONTROL_PORT (or $PICO_CONTROL_PORT). A client speaks the same frame protocol as on the
serial port, but only fingerprint admin frames (T_FP) are passed to the token, and only T_FP replies come back; PING is
answered locally. One client at a time; a second one is closed at once. fpctl.py connects here when a bridge is running.

Only processes on this machine can connect. Changing fingerprints still needs a touch with an enrolled finger (except
the very first enrolment), because the token itself asks for it.
"""
import os
import socket

from serial_frames import Decoder, encode, T_FP, T_PING, T_PONG, PONG_ID

CONTROL_PORT = 47731


def control_port():
    return int(os.environ.get("PICO_CONTROL_PORT", CONTROL_PORT))


def control_url():
    return f"tcp://127.0.0.1:{control_port()}"


class _Sock:
    """Wraps a socket so multiplex.wait_readable() can use it like a link."""

    def __init__(self, sock):
        self.sock = sock

    def fileno(self):
        return self.sock.fileno()


class ControlServer:
    def __init__(self, port=None, log=None):
        self.log = log or (lambda *a: None)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if os.name != "nt":
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", control_port() if port is None else port))
        self.listener.listen(2)
        self.listener.setblocking(False)
        self.port = self.listener.getsockname()[1]
        self.client = None
        self.dec = Decoder()

    def selectables(self):
        return [_Sock(self.listener)] + ([_Sock(self.client)] if self.client else [])

    def disconnect_client(self):
        if self.client:
            self.client.close()
            self.client = None

    def service(self):
        """Accept/read without blocking. Returns the T_FP payloads the client sent, to forward to the token."""
        while True:
            try:
                conn, _ = self.listener.accept()
            except (BlockingIOError, OSError):
                break
            if self.client:
                conn.close()                         # one admin client at a time
                self.log("control: second client refused")
                continue
            conn.setblocking(False)
            self.client, self.dec = conn, Decoder()
            self.log("control: fpctl connected")
        out = []
        while self.client:
            try:
                chunk = self.client.recv(512)
            except BlockingIOError:
                break
            except OSError:
                chunk = b""
            if not chunk:
                self.disconnect_client()
                self.log("control: fpctl disconnected")
                break
            for ftype, data in self.dec.feed(chunk):
                if ftype == T_FP:
                    out.append(data)
                elif ftype == T_PING:
                    self.send(encode(T_PONG, PONG_ID))
        return out

    def send(self, frame):
        """Send a raw frame to the client, if one is connected."""
        if not self.client:
            return
        try:
            self.client.setblocking(True)
            self.client.settimeout(1.0)
            self.client.sendall(frame)
        except OSError:
            self.disconnect_client()
        else:
            self.client.setblocking(False)

    def close(self):
        self.disconnect_client()
        self.listener.close()
