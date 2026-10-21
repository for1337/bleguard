#!/usr/bin/env bash
# install.sh — copy bleguard plugin files into ~/.config/omarchy/plugins/bleguard/.
# With --enable also adds it to shell.json and places the bar widget.
# Re-running is safe; pass --force to overwrite a real folder at the target.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="bleguard"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

# Files that make up the plugin (everything else in the repo is dev tooling).
# bleguard-discovery.py is the filtered-discovery helper: it holds a BlueZ
# discovery session open so the RSSI property is republished on every
# advertisement instead of every 8 dBm of movement.
PLUGIN_FILES=(manifest.json Panel.qml Service.qml BleLogic.js bleguard-discovery.py)

enable=""
force=""
while [ $# -gt 0 ]; do
  case "$1" in
    --enable) enable=1 ;;
    --force)  force=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 64
      ;;
  esac
  shift
done

for f in "${PLUGIN_FILES[@]}"; do
  if [ ! -f "$REPO_DIR/$f" ]; then
    echo "error: missing $REPO_DIR/$f (repo layout changed?)" >&2
    exit 1
  fi
done

# 1. Install plugin files -----------------------------------------------
mkdir -p "$PLUGIN_DST"

if [ -L "$PLUGIN_DST" ]; then
  if [ "$force" = "1" ]; then
    rm -f "$PLUGIN_DST"
  else
    echo "error: $PLUGIN_DST is a symlink. Pass --force to replace it with a real folder, or remove it manually first." >&2
    exit 1
  fi
fi

if [ -d "$PLUGIN_DST" ] && [ "$force" != "1" ] && [ -f "$PLUGIN_DST/manifest.json" ]; then
  echo "ok: $PLUGIN_DST already installed (manifest.json present). Pass --force to overwrite."
else
  if [ -d "$PLUGIN_DST" ] && [ "$force" = "1" ]; then
    rm -rf "$PLUGIN_DST"
    mkdir -p "$PLUGIN_DST"
  fi
  for f in "${PLUGIN_FILES[@]}"; do
    cp "$REPO_DIR/$f" "$PLUGIN_DST/$f"
  done
  # The helper is launched through "python3 <script>", but the executable
  # bit keeps it usable when it is called directly.
  chmod +x "$PLUGIN_DST/bleguard-discovery.py" 2>/dev/null || true
  echo "ok: copied ${PLUGIN_FILES[*]} -> $PLUGIN_DST"
fi

# 2. Optional: enable in shell.json --------------------------------------
if [ "$enable" = "1" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: --enable requires 'jq' to edit $SHELL_JSON safely." >&2
    echo "       Install it, or edit shell.json by hand." >&2
    exit 1
  fi

  if [ ! -f "$SHELL_JSON" ]; then
    echo "error: $SHELL_JSON not found. Run 'omarchy' once to create it, then retry." >&2
    exit 1
  fi

  tmp="$(mktemp)"
  jq --arg id "$PLUGIN_ID" '
    .plugins = ( (.plugins // [])
                 | if any(.id == $id) then . else . + [{id: $id}] end )
  ' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
  echo "ok: ensured '$PLUGIN_ID' is listed in $SHELL_JSON"

  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 \
      && echo "ok: enabled and placed bar widget (section: right)" \
      || echo "note: could not auto-place the bar widget — run:" \
              "omarchy bar move $PLUGIN_ID --section right"
  else
    echo "note: 'omarchy' not on PATH. Add a bar slot manually, e.g.:"
    echo "  omarchy bar move $PLUGIN_ID --section right"
  fi
else
  cat <<EOF

Next steps:
  1. Add the plugin to ~/.config/omarchy/shell.json:
         "plugins": [ { "id": "$PLUGIN_ID" } ]
  2. Enable it (also places the bar widget in the right section):
         omarchy plugin enable $PLUGIN_ID --section right
  3. Reload the shell so the service starts:
         omarchy restart shell
EOF
fi
