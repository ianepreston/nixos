#!/usr/bin/env bash
# The one place a closure is activated (#1018). Runs ON THE MACHINE BEING
# ACTIVATED (as root), either locally via sudo or on a remote host through the
# single ssh connection that scripts/activate-nixos.sh opens for this step.
#
#   activate.sh <expected-host> <closure> <check|switch|boot|test>
#
# The identity assertions and the activation are one && chain in one process,
# so nothing can route the check to one machine and the activation to another.
# There is no retry and no fallback: any failure stops here.
set -euo pipefail

host=${1:?expected host}
closure=${2:?closure path}
action=${3:?action}

die() {
  printf 'activate: %s\n' "$*" >&2
  exit 1
}

actual=$(hostname)
[ "$actual" = "$host" ] || die "refusing: this machine is '$actual', expected '$host'"

case ${closure##*/} in
  *-nixos-system-"$host"-*) ;;
  *) die "refusing: closure '$closure' is not a nixos-system-$host closure" ;;
esac

case $action in
  check)
    printf 'activate: identity ok (%s, %s)\n' "$actual" "${closure##*/}"
    exit 0
    ;;
  switch | boot | test) ;;
  *) die "unsupported action '$action'" ;;
esac

[ -x "$closure/bin/switch-to-configuration" ] || die "closure is missing or not a NixOS system: $closure"

# Same bookkeeping nixos-rebuild does: record the generation first (switch and
# boot only), then run switch-to-configuration detached from this session's
# lifetime so a dropped ssh connection cannot kill it halfway.
if [ "$action" != test ]; then
  nix-env --profile /nix/var/nix/profiles/system --set "$closure"
fi
exec systemd-run --setenv=LOCALE_ARCHIVE --collect --no-ask-password --pipe --quiet \
  --service-type=exec --unit=nixos-rebuild-switch-to-configuration \
  "$closure/bin/switch-to-configuration" "$action"
