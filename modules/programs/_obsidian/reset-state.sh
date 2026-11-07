# shellcheck shell=bash
# Keep Obsidian on the Nix-packaged build (#915). Usage:
#   obsidian-reset-state <config dir> <package store path>
# writeShellApplication supplies the shebang and `set -euo pipefail`.

config_dir=$1
package=$2

# obsidian.json is rewritten by a running instance whenever it saves, which
# would drop our edit. Activation runs again on the next switch and at boot.
if pgrep -f '/share/obsidian/app\.asar' >/dev/null; then
  echo "obsidian-reset-state: Obsidian is running, leaving its state alone" >&2
  exit 0
fi

mkdir -p "$config_dir"

# Stop new self-update downloads. The file also holds the vault list the app
# writes, so merge rather than replace.
settings=$config_dir/obsidian.json
[ -s "$settings" ] || echo '{}' >"$settings"
if [ "$(jq '.updateDisabled' "$settings")" != true ]; then
  jq -c '.updateDisabled = true' "$settings" >"$settings.tmp"
  mv "$settings.tmp" "$settings"
fi

# The bundled loader runs any downloaded asar at least as new as the packaged
# one, updateDisabled or not, so remove the ones already downloaded.
rm -f "$config_dir"/obsidian-*.asar

# A new Electron can misread the V8 code cache an older one wrote and render a
# blank window (NixOS/nixpkgs#578970). The package path moves with both the
# Electron and the app bundle, so it is the stamp.
stamp=$config_dir/.nix-package
if [ "$(cat "$stamp" 2>/dev/null || true)" != "$package" ]; then
  rm -rf "$config_dir/Cache" "$config_dir/Code Cache" "$config_dir/GPUCache"
  echo "$package" >"$stamp"
fi
