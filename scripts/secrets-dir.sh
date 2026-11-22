#!/usr/bin/env bash
# Print the nix-secrets checkout that `task secrets:*` operates on (#1042).
#
# Order: $SECRETS_DIR (also `task secrets:<x> SECRETS_DIR=...`), then
# $NIX_SECRETS_PATH (the variable scripts/activate-nixos.sh --local-secrets
# reads), then ../nix-secrets beside this checkout, then ../nix-secrets beside
# the primary checkout when run from a linked worktree. Prints the first
# candidate that exists, or the explicit / sibling path when none does, and
# never fails: Task evaluates this for every secrets task, so the consumer
# reports the missing directory.
#
# usage: scripts/secrets-dir.sh [NIXOS_DIR]
set -euo pipefail

nixos=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}

absolute() { (cd "$1" && pwd); }

for explicit in "${SECRETS_DIR:-}" "${NIX_SECRETS_PATH:-}"; do
  if [ -n "$explicit" ]; then
    if [ -d "$explicit" ]; then absolute "$explicit"; else printf '%s\n' "$explicit"; fi
    exit 0
  fi
done

if [ -d "$nixos/../nix-secrets" ]; then
  absolute "$nixos/../nix-secrets"
  exit 0
fi
if common=$(git -C "$nixos" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  [ -d "$common/../../nix-secrets" ]; then
  absolute "$common/../../nix-secrets"
  exit 0
fi
printf '%s\n' "$nixos/../nix-secrets"
