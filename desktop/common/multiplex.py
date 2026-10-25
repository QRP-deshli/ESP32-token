"""
multiplex.py - wait until one of several links has data, where the OS allows it.

    ready = wait_readable([hid, ser], 0.5)    # the subset that is readable now (maybe empty after the timeout),
                                              # or None: some source has no selectable fileno(), poll them instead

Linux and macOS: serial ports, uhid, pipes and sockets are all selectable file descriptors. Windows: select() only
works on sockets, so the serial and helper backends return fileno() None and the caller falls back to polling.
"""
import select


def wait_readable(sources, timeout):
    fds = [s.fileno() for s in sources]
    if None in fds:
        return None
    r, _, _ = select.select(fds, [], [], timeout)
    return [s for s, fd in zip(sources, fds) if fd in r]
