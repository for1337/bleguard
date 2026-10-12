#!/usr/bin/env bash
# install-lock-unlock-ipc.sh
#
# Adds an `unlock` method to Omarchy's lock plugin IpcHandler so that
# leo.bleguard can request an unlock via BLE-proximity proximity proof
# without going through PAM. Idempotent: safe to re-run.
#
# Apply with sudo:
#   sudo bash patches/install-lock-unlock-ipc.sh
#
# Reverts via:
#   sudo bash patches/install-lock-unlock-ipc.sh --revert

set -euo pipefail

LOCK="/usr/share/omarchy/shell/plugins/lock/Service.qml"

if [[ ! -f "$LOCK" ]]; then
  echo "error: $LOCK not found" >&2
  exit 1
fi

REVERT="false"
[[ "${1:-}" == "--revert" ]] && REVERT="true"

# The block we add (must match exactly what's already in the file, with leading
# 4-space indentation, so patch sees it as context).
BLOCK='    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    // Added by leo.bleguard for BLE-proximity auto-unlock.
    // Bypasses PAM — caller proves presence via BLE proximity +
    // stable-presence timer. Security trade-off: a relay attacker within
    // BLE range could trigger this. Acceptable in trusted environments,
    // equivalent to macOS / Windows smart-unlock.
    function unlock(): string {
      if (!root.locked) return "not-locked"
      root.finishUnlock()
      return "ok"
    }

    function isLocked(): string {'

if [[ "$REVERT" == "true" ]]; then
  # Revert: remove the unlock() block
  python3 - "$LOCK" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
new = re.sub(
    r'\n    // Added by leo\.bleguard.*?return "ok"\n    \}\n\n',
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
else
  if grep -q "Added by leo.bleguard" "$LOCK"; then
    echo "already applied, skipping"
    exit 0
  fi
  python3 - "$LOCK" <<'PY'
import sys
path, replacement = sys.argv[1], sys.argv[2]
src = open(path).read()
needle = '''    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {'''
if needle not in src:
    print("error: anchor not found in " + path)
    sys.exit(1)
addon = '''    // Added by leo.bleguard for BLE-proximity auto-unlock.
    // Bypasses PAM — caller proves presence via BLE proximity +
    // stable-presence timer. Security trade-off: a relay attacker within
    // BLE range could trigger this. Acceptable in trusted environments,
    // equivalent to macOS / Windows smart-unlock.
    function unlock(): string {
      if (!root.locked) return "not-locked"
      root.finishUnlock()
      return "ok"
    }

'''
patched = src.replace(needle, needle.replace("    function isLocked", addon + "    function isLocked"))
with open(path, 'w') as f:
    f.write(patched)
print("applied")
PY
fi