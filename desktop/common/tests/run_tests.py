#!/usr/bin/env python3
"""Runs every host test in this folder: all test_*.py files (each one skips the parts its OS cannot run) and the two C
tests of firmware code, built with $CC (default: cc, or gcc on Windows). Exit code 0 only if everything passed.

    python3 run_tests.py            # everything
    python3 run_tests.py --no-c     # Python tests only
    python3 run_tests.py fpctl      # only the tests whose name contains "fpctl"
"""
import glob, os, shutil, subprocess, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
sdk = os.path.normpath(os.path.join(here, "..", "..", "..", "pico-keys-sdk", "src"))
C_TESTS = {
    "test_fp_core.c": ["fingerprint/fp_core.c", "fingerprint/fp_proto.c"],
    "test_serial_proto.c": ["usb/serial/serial_proto.c"],
}


def run(name, cmd):
    t0 = time.monotonic()
    p = subprocess.run(cmd, cwd=here, capture_output=True, text=True)
    ok = p.returncode == 0
    print(f"{'ok  ' if ok else 'FAIL'} {name} ({time.monotonic() - t0:.1f} s)", flush=True)
    if not ok:
        print(p.stdout + p.stderr)
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    results = []
    for path in sorted(glob.glob(os.path.join(here, "test_*.py"))):
        name = os.path.basename(path)
        if not args or any(a in name for a in args):
            results.append(run(name, [sys.executable, path]))
    if "--no-c" not in sys.argv:
        cc = os.environ.get("CC") or ("gcc" if os.name == "nt" else "cc")
        if not shutil.which(cc):
            print(f"skip C tests: no C compiler ({cc})")
        else:
            out = tempfile.mkdtemp()
            for test, sources in C_TESTS.items():
                if args and not any(a in test for a in args):
                    continue
                exe = os.path.join(out, test[:-2] + (".exe" if os.name == "nt" else ""))
                inc = os.path.join(sdk, os.path.dirname(sources[0]))
                built = run(f"{test} (build)", [cc, f"-I{inc}", test] + [os.path.join(sdk, s) for s in sources] + ["-o", exe])
                results.append(built and run(test, [exe]))
    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
