"""A fake token for the host tests: speaks the serial frame protocol on a TCP port (every OS) or a pty (Linux, macOS).

    tok = FakeToken(handler, greeting=b"boot noise")     # handler(ftype, data, send) answers one frame
    url = tok.serve_tcp()                                # "tcp://127.0.0.1:NNNN", usable as --port
    path = tok.serve_pty()                               # "/dev/ttysNNN" or "/dev/pts/N"
    tok.inject(raw_bytes)                                # write raw bytes to the current connection
"""
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from serial_frames import Decoder, encode, T_PING, T_PONG, PONG_ID   # noqa: E402

HAVE_PTY = os.name != "nt"


class FakeToken:
    def __init__(self, handler, greeting=b""):
        self.handler = handler
        self.greeting = greeting
        self.stop = False
        self._write = None              # raw writer of the current connection

    def _serve(self, read, write):
        """Run the protocol on one connection until it ends. read() returns b"" when the peer is gone."""
        dec = Decoder()
        self._write = write
        if self.greeting:
            write(self.greeting)

        def send(ftype, data=b""):
            write(encode(ftype, data))
        while not self.stop:
            chunk = read()
            if chunk is None:
                return
            for t, d in dec.feed(chunk):
                if t == T_PING:
                    send(T_PONG, PONG_ID)
                else:
                    self.handler(t, bytes(d), send)

    def inject(self, raw):
        self._write(raw)

    # --- TCP: one connection at a time (the probe connects and leaves, then the real user connects)
    def serve_tcp(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)

        def accept_loop():
            while not self.stop:
                conn, _ = srv.accept()
                conn.settimeout(0.05)

                def read(conn=conn):
                    try:
                        data = conn.recv(512)
                    except socket.timeout:
                        return b""
                    except OSError:
                        return None
                    return data or None
                try:
                    self._serve(read, conn.sendall)
                except OSError:
                    pass
                conn.close()
        threading.Thread(target=accept_loop, daemon=True).start()
        return "tcp://127.0.0.1:%d" % srv.getsockname()[1]

    # --- pty: the master side stays open, so clients can open and close the slave as often as they like
    def serve_pty(self):
        import pty
        master, slave = pty.openpty()
        os.set_blocking(master, False)
        path = os.ttyname(slave)

        def read():
            try:
                return os.read(master, 512)
            except (BlockingIOError, OSError):
                time.sleep(0.005)
                return b""
        threading.Thread(target=self._serve, args=(read, lambda b: os.write(master, b)), daemon=True).start()
        self._slave = slave             # keep it open: closing the last slave fd makes master reads fail on Linux
        return path


class Checker:
    def __init__(self):
        self.fails = 0

    def __call__(self, cond, msg):
        print(("PASS " if cond else "FAIL ") + msg, flush=True)
        if not cond:
            self.fails += 1

    def finish(self):
        print("ALL PASSED" if not self.fails else f"{self.fails} FAILED")
        sys.exit(1 if self.fails else 0)
