#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixtures="$repo_root/scripts/testdata/reconcile-ha-component-requirements"
reconciler="$repo_root/scripts/reconcile-ha-component-requirements.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT INT TERM

fail() {
  echo "test-reconcile-ha-component-requirements: $*" >&2
  exit 1
}

assert_rejected() {
  local description=$1
  cp "$scratch/homeassistant.nix" "$scratch/before-invalid.nix"
  if HA_REQUIREMENTS_MANIFEST_DIR="$scratch/manifests" \
    HA_REQUIREMENTS_PYPI_HASH_DIR="$fixtures/hashes" \
    "$reconciler" --file "$scratch/homeassistant.nix"; then
    fail "accepted $description"
  fi
  cmp -s "$scratch/before-invalid.nix" "$scratch/homeassistant.nix" || fail "$description rewrote Nix source"
}

cp "$fixtures/homeassistant.fixture" "$scratch/homeassistant.nix"
cp -R "$fixtures/manifests" "$scratch/manifests"

HA_REQUIREMENTS_MANIFEST_DIR="$scratch/manifests" \
  HA_REQUIREMENTS_PYPI_HASH_DIR="$fixtures/hashes" \
  "$reconciler" --file "$scratch/homeassistant.nix"

grep -F 'version = "1.56.4";' "$scratch/homeassistant.nix" >/dev/null || fail "did not update blueair package version"
grep -F 'hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";' "$scratch/homeassistant.nix" >/dev/null || fail "did not update blueair PyPI hash"
grep -F 'version = "0.5.5";' "$scratch/homeassistant.nix" >/dev/null || fail "changed matching Hoymiles version"

cp "$scratch/homeassistant.nix" "$scratch/unchanged.nix"
HA_REQUIREMENTS_MANIFEST_DIR="$scratch/manifests" \
  HA_REQUIREMENTS_PYPI_HASH_DIR="$fixtures/hashes" \
  "$reconciler" --file "$scratch/homeassistant.nix"
cmp -s "$scratch/unchanged.nix" "$scratch/homeassistant.nix" || fail "matching requirements were not a no-op"

sed -i.bak 's/hoymiles-wifi==0.5.5/hoymiles-wifi==0.5.6/' \
  "$scratch/manifests/suaveolent__ha-hoymiles-wifi__v0.5.1__hoymiles_wifi.json"
rm "$scratch/manifests/suaveolent__ha-hoymiles-wifi__v0.5.1__hoymiles_wifi.json.bak"
HA_REQUIREMENTS_MANIFEST_DIR="$scratch/manifests" \
  HA_REQUIREMENTS_PYPI_HASH_DIR="$fixtures/hashes" \
  "$reconciler" --file "$scratch/homeassistant.nix"
grep -F 'version = "0.5.6";' "$scratch/homeassistant.nix" >/dev/null || fail "did not update Hoymiles package version"
grep -F 'tag = "v0.5.6";' "$scratch/homeassistant.nix" >/dev/null || fail "did not update Hoymiles package tag"
grep -F 'tag = "v0.5.1";' "$scratch/homeassistant.nix" >/dev/null || fail "rewrote Hoymiles component tag"

sed -i.bak 's/blueair-api==1.56.4/blueair-api>=1.56.4/' \
  "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json"
rm "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json.bak"
assert_rejected "a non-exact requirement"

cp "$fixtures/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json" "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json"
sed -i.bak 's/"\]$/", "unmapped==1.0"]/' \
  "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json"
rm "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json.bak"
assert_rejected "an additional unmapped requirement"

cp "$fixtures/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json" "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json"
sed -i.bak 's/\["blueair-api==1.56.4"\]/[]/' \
  "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json"
rm "$scratch/manifests/dahlb__ha_blueair__0123456789abcdef__ha_blueair.json.bak"
assert_rejected "a missing requirement"

printf '%s\n' 'test-reconcile-ha-component-requirements: ok'
