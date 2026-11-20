# shellcheck shell=bash
# Write the host's own age identity, derived from its SSH host key, where
# home-manager sops reads it. Runs as the primary user from
# sops-host-age-identity.service, which passes the root-only host key in as
# the `host-key` systemd credential.
#
# Usage: sops-host-age-identity AGE_DIR
#
# The age recipient of every host in nix-secrets' .sops.yaml is `ssh-to-age`
# of this same key, so the identity decrypts exactly the files that list the
# host and nothing else.

age_dir=$1
host_key="$CREDENTIALS_DIRECTORY/host-key"

mkdir -p "$age_dir"

# Before #504, sops-nix linked the operator key here from shared.yaml's
# `keys/age`. That secret is gone, so the link dangles; remove it so the sops
# CLI falls through cleanly and home-manager can install the operator stubs at
# this path on authoring hosts without a "file is in the way" collision.
legacy="$age_dir/keys.txt"
if [ -L "$legacy" ] && [ "$(readlink "$legacy")" = /run/secrets/keys/age ]; then
  rm -f "$legacy"
fi

# The unit's UMask=0077 makes this 0600 from creation, and the rename means
# home-manager sops never reads a half-written file.
tmp=$(mktemp "$age_dir/.host.txt.XXXXXX")
trap 'rm -f "$tmp"' EXIT
ssh-to-age -private-key -i "$host_key" -o "$tmp"
mv -f "$tmp" "$age_dir/host.txt"
trap - EXIT
