# shellcheck shell=bash
# Install the Nix-declared BepInEx plugin tree into the Valheim container's
# /config/bepinex before the container starts (#772). Runs as an ExecStartPre
# of podman-valheim.service, so every start — deploy, manual restart, reboot —
# re-asserts the declaration.
#
# Usage: valheim-bepinex-materialize <declared-tree> <bepinex-config-dir> <uid> <gid>
#
#   declared-tree       merged store path of `myValheim.bepinexPlugins`, in the
#                       layout documented in bepinex-plugins.nix (may be empty)
#   bepinex-config-dir  host path the container sees as /config/bepinex
#
# What this owns, and nothing else:
#
#   plugins/nix-managed/, patchers/nix-managed/
#       Replaced wholesale on every run. The image's valheim-bootstrap then
#       rsyncs /config/bepinex/{plugins,patchers} into the install tree and,
#       from its own .synced_from_config manifest, prunes whatever an earlier
#       sync installed that is no longer here — so a removed plugin leaves the
#       running tree on the next start. BepInEx scans both directories
#       recursively, so the subdirectory loads like any other.
#
#   <guid>.cfg named in .nix-managed-configs
#       /config/bepinex is BepInEx's config directory (the image symlinks
#       BepInEx/config to it). A declared config is written over on every run;
#       a config this script wrote earlier and that is no longer declared is
#       deleted. Configs it never wrote — BepInEx.cfg, anything a plugin
#       generated for itself, anything placed by hand — are left alone.
#
# Everything else under /config/bepinex, including hand-dropped DLLs directly
# in plugins/, is unmanaged local exploration and survives untouched.
#
# Copies rather than symlinks: the container cannot see /nix/store, and the
# image's rsync -a would carry a symlink across as a dangling one.
#
# writeShellApplication already sets errexit/nounset/pipefail; repeated so
# the file stands alone under shellcheck and by hand.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <declared-tree> <bepinex-config-dir> <uid> <gid>" >&2
  exit 64
fi

src=$1
dest=$2
uid=$3
gid=$4
managed=nix-managed
manifest="$dest/.nix-managed-configs"

install -d -o "$uid" -g "$gid" "$dest"

for kind in plugins patchers; do
  target="$dest/$kind/$managed"
  rm -rf "$target"
  if [[ -d "$src/BepInEx/$kind" ]]; then
    install -d -o "$uid" -g "$gid" "$dest/$kind"
    cp -RL --no-preserve=mode,ownership "$src/BepInEx/$kind" "$target"
    chown -R "$uid:$gid" "$target"
    echo "valheim-bepinex-materialize: installed $kind/$managed:"
    (cd "$target" && find . ! -type d | sort | sed 's|^\./|  |')
  fi
done

declared=()
if [[ -d "$src/BepInEx/config" ]]; then
  shopt -s nullglob
  for cfg in "$src"/BepInEx/config/*.cfg; do
    declared+=("$(basename "$cfg")")
  done
  shopt -u nullglob
fi

is_declared() {
  local name=$1 d
  for d in "${declared[@]}"; do
    [[ $d == "$name" ]] && return 0
  done
  return 1
}

if [[ -f $manifest ]]; then
  while IFS= read -r old; do
    [[ -z $old ]] && continue
    # The manifest only ever holds basenames this script wrote; refuse
    # anything else rather than following it out of $dest.
    [[ $old == */* ]] && continue
    if ! is_declared "$old"; then
      echo "valheim-bepinex-materialize: removing undeclared $old"
      rm -f "$dest/$old"
    fi
  done <"$manifest"
fi

for name in "${declared[@]}"; do
  install -m 0644 -o "$uid" -g "$gid" "$src/BepInEx/config/$name" "$dest/$name"
  echo "valheim-bepinex-materialize: wrote $name"
done

printf '%s\n' "${declared[@]}" | sed '/^$/d' >"$manifest.tmp"
mv "$manifest.tmp" "$manifest"
