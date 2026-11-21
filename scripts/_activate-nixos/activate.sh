#!/usr/bin/env bash
# The one place a closure is activated (#1018). Runs ON THE MACHINE BEING
# ACTIVATED (as root), either locally via sudo or on a remote host through the
# single ssh connection that scripts/activate-nixos.sh opens for this step.
#
#   activate.sh <expected-host> <closure> <check|switch|boot|test> <nonce> [caller-verified]
#
# The identity assertions and the activation run in one process under set -e,
# so nothing can route the check to one machine and the activation to another.
# There is no retry and no fallback: any failure stops here.
#
# Two sentinel lines on stdout prove to the caller that this script really ran
# (an ssh that never fed it to bash would otherwise exit 0):
#   ACTIVATE-NIXOS-VERIFIED <nonce> <host> <action>   after the identity checks
#   ACTIVATE-NIXOS-DONE <nonce>                       after the action succeeded
set -euo pipefail

store_dir=/nix/store

host=${1:?expected host}
closure=${2:?closure path}
action=${3:?action}
nonce=${4:?nonce}
# Only `check` may run against a closure that is absent here, and only when the
# caller says it already verified that closure (name and etc/hostname) locally.
caller_verified=${5-}

die() {
  printf 'activate: %s\n' "$*" >&2
  exit 1
}

case $action in check | switch | boot | test) ;; *) die "unsupported action '$action'" ;; esac
[[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid host '$host'"
[[ $nonce =~ ^[0-9a-f]{16,64}$ ]] || die "invalid nonce"

actual=$(hostname)
[ "$actual" = "$host" ] || die "refusing: this machine is '$actual', expected '$host'"

# The name must be exactly <store>/<32-char hash>-nixos-system-<host>-<version>.
# A hyphenated host makes the name alone ambiguous (host "hpp" vs "hpp-1"), so
# the closure's own etc/hostname is also checked exactly, below.
name_re="^${store_dir}/[0-9abcdfghijklmnpqrsvwxyz]{32}-nixos-system-${host}-[0-9]{2}\\.[0-9]{2}[0-9A-Za-z._+-]*\$"
[[ $closure =~ $name_re ]] || die "refusing: closure '$closure' is not a nixos-system-$host closure"

if [ -e "$closure" ]; then
  [ -r "$closure/etc/hostname" ] || die "refusing: closure has no etc/hostname: $closure"
  configured=$(<"$closure/etc/hostname")
  [ "$configured" = "$host" ] || die "refusing: closure is configured for host '$configured', expected '$host'"
elif [ "$action" != check ] || [ "$caller_verified" != caller-verified ]; then
  die "closure is not present on this machine: $closure"
fi

printf 'ACTIVATE-NIXOS-VERIFIED %s %s %s\n' "$nonce" "$host" "$action"

if [ "$action" = check ]; then
  printf 'activate: identity ok (%s, %s)\n' "$actual" "${closure##*/}" >&2
  printf 'ACTIVATE-NIXOS-DONE %s\n' "$nonce"
  exit 0
fi

[ -x "$closure/bin/switch-to-configuration" ] || die "closure is not a NixOS system: $closure"

# Same bookkeeping nixos-rebuild does: record the generation first (switch and
# boot only), then run switch-to-configuration as a transient systemd unit with
# the flags nixos-rebuild uses. That gives it its own cgroup outside this login
# session, so stopping or restarting units the session belongs to does not take
# the activation down with it. It is NOT detached from this connection: --pipe
# wires its stdio to ours, so a dropped connection can still interrupt it (a
# write to the closed pipe gets SIGPIPE). Never assume an interrupted run
# finished; inspect the target first.
#
# stdin and stdout are shared with the caller: under `ssh host sudo bash -s`
# stdin is this very script, and stdout carries the sentinel lines. So the
# activation gets stdin from /dev/null (it cannot swallow the rest of this
# script) and its stdout goes to stderr (its output, with or without a trailing
# newline, can never fuse with a sentinel). Exit status is unaffected; set -e
# stops here on failure.
{
  if [ "$action" != test ]; then
    nix-env --profile /nix/var/nix/profiles/system --set "$closure"
  fi
  systemd-run --setenv=LOCALE_ARCHIVE --collect --no-ask-password --pipe --quiet \
    --service-type=exec --unit=nixos-rebuild-switch-to-configuration \
    "$closure/bin/switch-to-configuration" "$action"
} </dev/null >&2

printf 'ACTIVATE-NIXOS-DONE %s\n' "$nonce"
