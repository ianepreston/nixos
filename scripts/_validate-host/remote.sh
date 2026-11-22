#!/usr/bin/env bash
# Read-only target side of scripts/validate-host.py (#1063). The driver feeds
# this file on stdin to `ssh <target> bash -s -- <expected-host> <nonce>` and
# appends ONE command line: `state`, or `probe` with the caller's probe text as
# a quoted here-document. Nothing here changes the host.
#
# The hostname is asserted first, in the same process as every read, so a
# connection that reached another machine reports nothing but the refusal.
# Sentinel lines carry the driver's nonce; without them the driver treats the
# read as failed even if ssh exited 0.
set -u

expected_host=${1:?expected host}
nonce=${2:?nonce}

actual=$(hostname 2>/dev/null) || actual=""
if [ "$actual" != "$expected_host" ]; then
  printf 'VALIDATE-WRONG-HOST\n'
  exit 97
fi

# Key=value lines only; values are store paths, unit names and states.
state() {
  local failed unit
  printf 'hostname=%s\n' "$actual"
  printf 'current_system=%s\n' "$(readlink /run/current-system 2>/dev/null)"
  printf 'booted_system=%s\n' "$(readlink /run/booted-system 2>/dev/null)"
  printf 'system_profile=%s\n' "$(readlink /nix/var/nix/profiles/system 2>/dev/null)"
  printf 'system_state=%s\n' "$(systemctl is-system-running 2>/dev/null)"
  failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null) || failed=""
  while read -r unit _; do
    [ -z "$unit" ] || printf 'failed_unit=%s\n' "$unit"
  done <<<"$failed"
  printf 'upgrade_service=%s\n' "$(systemctl is-active nixos-upgrade.service 2>/dev/null)"
  printf 'upgrade_timer_next=%s\n' "$(systemctl show nixos-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
  printf 'VALIDATE-END %s\n' "$nonce"
}

# The probe text arrives on this function's stdin (a here-document), so it can
# never read the rest of this script; the probe itself gets /dev/null.
probe() {
  local text rc
  text=$(cat)
  bash -c "$text" </dev/null
  rc=$?
  printf '\nVALIDATE-PROBE-RC %s %s\n' "$nonce" "$rc"
}
