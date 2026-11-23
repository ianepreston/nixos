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

# A required read that fails (or prints nothing) ends the read with
# VALIDATE-READ-FAILED <key> and exit 98: the driver never records a missing
# value as an empty or zero one.
read_failed() {
  printf 'VALIDATE-READ-FAILED %s\n' "$1"
  exit 98
}

# Key=value lines only; values are store paths, unit names and states.
state() {
  local value failed unit link
  printf 'hostname=%s\n' "$actual"
  for link in current_system:/run/current-system booted_system:/run/booted-system \
    system_profile:/nix/var/nix/profiles/system; do
    value=$(readlink "${link#*:}" 2>/dev/null) && [ -n "$value" ] || read_failed "${link%%:*}"
    printf '%s=%s\n' "${link%%:*}" "$value"
  done
  # Exits non-zero for degraded/starting/...; the printed state is the result.
  value=$(systemctl is-system-running 2>/dev/null)
  [ -n "$value" ] || read_failed system_state
  printf 'system_state=%s\n' "$value"
  failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null) || read_failed failed_units
  while read -r unit _; do
    [ -z "$unit" ] || printf 'failed_unit=%s\n' "$unit"
  done <<<"$failed"
  # Exits non-zero for inactive (the expected state); empty output is a failure.
  value=$(systemctl is-active nixos-upgrade.service 2>/dev/null)
  [ -n "$value" ] || read_failed upgrade_service
  printf 'upgrade_service=%s\n' "$value"
  # Empty when the host has no upgrade timer; a failing systemctl is an error.
  value=$(systemctl show nixos-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null) || read_failed upgrade_timer_next
  printf 'upgrade_timer_next=%s\n' "$value"
  printf 'VALIDATE-END %s\n' "$nonce"
}

# The probe text arrives on this function's stdin (a here-document), so it can
# never read the rest of this script; the probe itself gets /dev/null and runs
# under pipefail, so `curl -f ... | consumer` fails when curl does.
probe() {
  local text rc
  text=$(cat)
  bash -o pipefail -c "$text" </dev/null
  rc=$?
  printf '\nVALIDATE-PROBE-RC %s %s\n' "$nonce" "$rc"
}
