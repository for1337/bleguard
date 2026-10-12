#!/usr/bin/env bash
# install.sh — symlink bleguard into ~/.config/omarchy/plugins/.
# With --enable also adds it to shell.json and places the bar widget.
# Re-running is safe; pass --force to overwrite a real folder at the target.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="bleguard"
PLUGIN_SRC="$REPO_DIR/$PLUGIN_ID"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

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

if [ ! -d "$PLUGIN_SRC" ]; then
  echo "error: $PLUGIN_SRC not found." >&2
  exit 1
fi

# 1. Symlink into the plugins directory ------------------------------------
mkdir -p "$(dirname "$PLUGIN_DST")"

if [ -e "$PLUGIN_DST" ] || [ -L "$PLUGIN_DST" ]; then
  if [ -L "$PLUGIN_DST" ] && [ "$(readlink "$PLUGIN_DST")" = "$PLUGIN_SRC" ]; then
    echo "ok: $PLUGIN_DST already points at $PLUGIN_SRC"
  elif [ "$force" = "1" ]; then
    rm -rf "$PLUGIN_DST"
    ln -s "$PLUGIN_SRC" "$PLUGIN_DST"
    echo "ok: replaced $PLUGIN_DST with symlink to $PLUGIN_SRC"
  else
    echo "error: $PLUGIN_DST already exists (not a symlink to this repo)." >&2
    echo "       Pass --force to overwrite, or remove it manually first." >&2
    exit 1
  fi
else
  ln -s "$PLUGIN_SRC" "$PLUGIN_DST"
  echo "ok: linked $PLUGIN_DST -> $PLUGIN_SRC"
fi

# 2. Optional: enable in shell.json ----------------------------------------
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