# macOS

**Not implemented yet.** Nothing in `common/` or `linux/` runs on macOS today.

What has to be built (each item is a GitHub issue in `../issues/`):

1. Serial detection and access for macOS (`/dev/cu.usbmodem*`), issue 04.
2. A virtual FIDO HID device, or another way for browsers to reach the token (issue 05, a research task first).
3. Helper scripts (zsh/bash) equivalent to `../linux/` (issue 06).
4. Tests and CI on macOS (issue 08), docs (issue 09).

Suggested layout once it exists (keep it parallel to `linux/`):

```
mac/
  setup-token.sh
  check-token.sh
  start-bridge.sh
  README.md
```

macOS ships bash 3.2 and zsh: avoid bash-4 features in the scripts.
