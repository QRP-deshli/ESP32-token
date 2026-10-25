# Windows

**Not implemented yet.** Nothing in `common/` or `linux/` runs on Windows today.

What has to be built (each item is a GitHub issue in `../issues/`):

1. A serial link that works with COM ports, detection of the token's port (issue 02).
2. A virtual FIDO HID device, or another way for browsers to reach the token (issue 03, a research task first).
3. Helper scripts (PowerShell) equivalent to `../linux/` (issue 06).
4. Tests and CI on Windows (issue 08), docs (issue 09).

Suggested layout once it exists (keep it parallel to `linux/`):

```
windows/
  setup-token.ps1
  check-token.ps1
  start-bridge.ps1
  README.md
```

To develop: flash the firmware from the top-level `README.md` Part A (ESP-IDF supports Windows; the steps there are
written for Ubuntu, adapting them is part of issue 09), plug the token's native USB port into the Windows PC, and check in
Device Manager that it appears as a COM port.
