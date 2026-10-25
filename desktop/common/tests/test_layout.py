#!/usr/bin/env python3
"""Checks the module layout of desktop/common statically, so OS-specific code cannot creep back into the portable parts:
   - serial_frames.py (the protocol) imports nothing OS-specific,
   - ctaphid_serial_bridge.py and fpctl.py use only the SerialLink / VirtualHid interfaces: no OS modules, no
     platform checks, no /dev paths outside their usage text."""
import ast, os

from fake_token import Checker

common = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OS_MODULES = {"termios", "tty", "pty", "fcntl", "select", "selectors", "ctypes", "winreg", "msvcrt", "glob", "socket",
              "subprocess"}
check = Checker()


def parse(name):
    with open(os.path.join(common, name)) as f:
        return ast.parse(f.read())


def imports(tree):
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            out.add(node.module.split(".")[0])
    return out


def platform_checks(tree):
    return [f"line {n.lineno}" for n in ast.walk(tree)
            if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)
            and (n.value.id, n.attr) in {("sys", "platform"), ("os", "name")}]


def dev_strings(tree):
    doc = ast.get_docstring(tree, clean=False)
    return [f"line {n.lineno}" for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and "/dev/" in n.value and n.value != doc]


frames = parse("serial_frames.py")
check(imports(frames) <= {"struct"}, f"serial_frames.py imports only struct: {sorted(imports(frames))}")

for name in ("ctaphid_serial_bridge.py", "fpctl.py"):
    tree = parse(name)
    bad = imports(tree) & OS_MODULES
    check(not bad, f"{name} imports no OS-specific module {sorted(bad) if bad else ''}")
    check(not platform_checks(tree), f"{name} has no sys.platform / os.name checks {platform_checks(tree) or ''}")
    check(not dev_strings(tree), f"{name} has no /dev paths outside its usage text {dev_strings(tree) or ''}")
    check({"serial_link", "serial_frames"} <= imports(tree), f"{name} uses serial_link and serial_frames")

check("virtual_hid" in imports(parse("ctaphid_serial_bridge.py")), "the bridge gets its virtual device from virtual_hid")
check.finish()
