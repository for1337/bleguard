#!/usr/bin/env bash
# install-lock-unlock-ipc.sh
#
# Adds an `unlock` method to Omarchy's lock plugin IpcHandler so that
# bleguard can request an unlock via BLE-proximity proximity proof
# without going through PAM. Idempotent: safe to re-run.
#
# Apply with sudo:
#   sudo bash patches/install-lock-unlock-ipc.sh
#
# Reverts via:
#   sudo bash patches/install-lock-unlock-ipc.sh --revert
#
# Overrides (for testing without touching the system):
#   BLEGUARD_LOCK_PLUGIN=/path/to/Service.qml

set -euo pipefail

LOCK="${BLEGUARD_LOCK_PLUGIN:-/usr/share/omarchy/shell/plugins/lock/Service.qml}"

if [[ ! -f "$LOCK" ]]; then
  echo "error: $LOCK not found" >&2
  exit 1
fi

REVERT="false"
[[ "${1:-}" == "--revert" ]] && REVERT="true"

# Marker string used to detect an already-patched file. Keep it in sync with
# the block inserted below AND with the revert regex.
MARKER="Added by bleguard for BLE-proximity auto-unlock"

if [[ "$REVERT" == "true" ]]; then
  # Revert: remove the unlock() block. The regex must match the exact text
  # the installer inserts — including the marker line — otherwise --revert
  # silently reports "nothing to revert" and leaves the patch in place.
  python3 - "$LOCK" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
new = re.sub(
    r'\n    // Added by bleguard for BLE-proximity auto-unlock\..*?return "ok"\n    \}\n\n',
    '\n',
    src,
    count=1,
    flags=re.DOTALL,
)
if new == src:
    print("nothing to revert")
    sys.exit(0)
with open(path, 'w') as f:
    f.write(new)
print("reverted")
PY
  exit 0
fi

if grep -q "$MARKER" "$LOCK"; then
  echo "already applied, skipping"
  exit 0
fi

python3 - "$LOCK" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# Anchor on the `isLocked()` method of the lock plugin's IpcHandler instead of
# the body of `lock()`. Omarchy's lock plugin has been refactored over time
# (e.g. `root.locked` -> `root.currentlyLocked()`), which broke the previous
# anchor and made the installer fail with "anchor not found" — the patch was
# therefore never applied and `ipc call lock unlock` answered
# "Function not found.". `isLocked()` is stable across those refactors and is
# unique in this file.
anchor = "    function isLocked(): string {"
if src.count(anchor) != 1:
    print("error: expected exactly one %r in %s, found %d"
          % (anchor, path, src.count(anchor)))
    sys.exit(1)

# Pick the lock-state API this Omarchy version exposes.
if "function currentlyLocked()" in src:
    state_check = "root.currentlyLocked()"
else:
    state_check = "root.locked"

addon = '''    // Added by bleguard for BLE-proximity auto-unlock.
    // Bypasses PAM — the caller proves presence via BLE proximity +
    // stable-presence timer. Security trade-off: a relay attacker within
    // BLE range could trigger this. Acceptable in trusted environments,
    // equivalent to macOS / Windows smart-unlock.
    function unlock(): string {
      if (!%s) return "not-locked"
      root.finishUnlock()
      return "ok"
    }

''' % state_check

patched = src.replace(anchor, addon + anchor, 1)

# Sanity check: the method must exist and the file must still be valid QML
# enough to contain balanced braces.
if "function unlock(): string {" not in patched:
    print("error: unlock() was not inserted")
    sys.exit(1)
if patched.count("{") != patched.count("}"):
    print("error: unbalanced braces after patch")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(patched)
print("applied (%s)" % state_check)
PY

echo "verify with: qs -p /usr/share/omarchy/shell ipc call lock status"
echo "then restart the shell: omarchy restart shell"
