# shellcheck shell=bash
# Sourced by every mySqliteQuiesce unit whose staged file names are only
# known at runtime, i.e. with an entry that globs its last path component
# (modules/system/sqlite-quiesce.nix), however many entries it has.
# Literal names are checked during evaluation; this is the same check once
# the globs have been resolved.
#
# Usage: stage_checked <sqlite3> <dstdir> (literal|resolved) <src> ...
#
# Every destination is checked before anything is written, so a collision
# or a name sqlite's unquoted `.backup` argument would alter leaves the
# previous staged copies untouched. A literal entry reserves its
# name even when its file is absent, because recovery maps that staged
# name back to the literal path. Absent literal files are then skipped, as
# in the unchecked unit; resolved glob matches are always copied.
#
# A staged name is the raw last path component (`${src##*/}`), never
# `$(basename ...)`: command substitution strips trailing newlines, which
# would validate one name and write another. The name checked is the name
# written.
stage_checked() {
  local sqlite3=$1 dstdir=$2
  shift 2
  local -a kinds=() srcs=() dsts=()
  local -A claimedBy=()
  local kind src dst i
  while [ "$#" -gt 0 ]; do
    kind=$1 src=$2
    shift 2
    dst=${src##*/}
    # .backup takes the name unquoted; see safeName in sqlite-quiesce.nix.
    case $dst in
      "" | *[!A-Za-z0-9._+@%,:=~-]*)
        echo "mySqliteQuiesce: $src stages as \`$dst\`, which sqlite's .backup cannot take unquoted; no staged copy was written" >&2
        return 1
        ;;
    esac
    if [ -n "${claimedBy[$dst]+set}" ]; then
      echo "mySqliteQuiesce: ${claimedBy[$dst]} and $src both stage to $dstdir/$dst; no staged copy was written" >&2
      return 1
    fi
    claimedBy[$dst]=$src
    kinds+=("$kind")
    srcs+=("$src")
    dsts+=("$dst")
  done
  for i in "${!srcs[@]}"; do
    if [ "${kinds[$i]}" = literal ] && [ ! -f "${srcs[$i]}" ]; then
      continue
    fi
    "$sqlite3" "${srcs[$i]}" ".backup $dstdir/${dsts[$i]}"
  done
}
