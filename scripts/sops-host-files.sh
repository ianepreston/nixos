#!/usr/bin/env bash
# Print, one per line, the nix-secrets sops files (basenames) that HOST's
# evaluated NixOS and home-manager secrets read. Only HOST is evaluated.
#
# Usage: scripts/sops-host-files.sh HOST SECRETS_DIR
#
# Shared by bootstrap:secrets and vm:sops-authorize so "which files does
# this host need" has one answer, the same one `task secrets:matrix`
# checks against (scripts/_sops-matrix/consumers.nix).
set -euo pipefail

host=$1
secrets_dir=$(realpath "$2")
repo=$(git rev-parse --show-toplevel)

nix eval --json "$repo#nixosConfigurations" \
  --override-input nix-secrets "path:$secrets_dir" \
  --apply "cs: ($(cat "$repo/scripts/_sops-matrix/consumers.nix")) { \"$host\" = cs.\"$host\"; }" |
  jq -er --arg h "$host" '.[$h] | if length == 0 then error("no sops files") else .[] end'
