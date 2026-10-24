#!/usr/bin/env bash
# Reconcile locally packaged Python libraries with Home Assistant custom
# components' exact manifest requirements.
#
# Renovate updates the component source pin. This script reads the manifest at
# that pin, updates the corresponding local fetchPypi source, and derives its
# hash. The mapping below is deliberately narrow: a missing, additional, or
# non-exact requirement is a change in package shape and must be reviewed.
#
# Usage: reconcile-ha-component-requirements.sh [--check] [--file PATH]
#
# Tests set HA_REQUIREMENTS_MANIFEST_DIR and HA_REQUIREMENTS_PYPI_HASH_DIR to
# avoid live network requests. Their fixture filenames are documented beside
# the respective lookup functions.
set -euo pipefail

source_file="modules/apps/homeassistant.nix"
check_only=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --check) check_only=true ;;
    --file)
      [[ $# -ge 2 ]] || {
        echo "reconcile-ha-component-requirements: --file needs a path" >&2
        exit 2
      }
      source_file=$2
      shift
      ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "reconcile-ha-component-requirements: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done

missing=()
for tool in awk cmp curl grep jq mktemp nix nix-prefetch-url sed; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "reconcile-ha-component-requirements: not on PATH: ${missing[*]}" >&2
  exit 127
fi

[[ -f $source_file ]] || {
  echo "reconcile-ha-component-requirements: no such source file: $source_file" >&2
  exit 2
}

# owner/repo | integration domain | local Nix binding | manifest project | source kind | PyPI pname
mappings=(
  "suaveolent/ha-hoymiles-wifi|hoymiles_wifi|hoymiles-wifi|hoymiles-wifi|github|-"
  "dahlb/ha_blueair|ha_blueair|blueair-api|blueair-api|pypi|blueair_api"
)

tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

new_tmp() {
  local file
  file=$(mktemp "$tmpdir/file.XXXXXX")
  printf '%s\n' "$file"
}

# Print the tag or rev of a component's fetchFromGitHub block.
component_ref() {
  local owner=$1 repo=$2
  awk -v wanted_owner="$owner" -v wanted_repo="$repo" '
    function qval(line) {
      if (match(line, /"[^"]*"/)) return substr(line, RSTART + 1, RLENGTH - 2)
      return ""
    }
    /^[[:space:]]*owner[[:space:]]*=/ && qval($0) == wanted_owner { owner_seen = 1; next }
    owner_seen && /^[[:space:]]*repo[[:space:]]*=/ && qval($0) == wanted_repo { repo_seen = 1; next }
    repo_seen && /^[[:space:]]*(tag|rev)[[:space:]]*=/ { print qval($0); exit }
  ' "$source_file"
}

# Fixture: <owner__repo>__<ref>__<domain>.json.
component_manifest() {
  local owner=$1 repo=$2 ref=$3 domain=$4 owner_repo manifest
  owner_repo="$owner/$repo"
  owner_repo=${owner_repo//\//__}
  manifest=$(new_tmp)
  if [[ -n ${HA_REQUIREMENTS_MANIFEST_DIR:-} ]]; then
    cp "$HA_REQUIREMENTS_MANIFEST_DIR/${owner_repo}__${ref}__${domain}.json" "$manifest"
  else
    curl --fail --location --silent --show-error \
      "https://raw.githubusercontent.com/$owner/$repo/$ref/custom_components/$domain/manifest.json" \
      >"$manifest"
  fi
  printf '%s\n' "$manifest"
}

# A mapped component must retain exactly its one known exact requirement.
manifest_version() {
  local manifest=$1 project=$2
  jq -er --arg project "$project" '
    if (.requirements | type) != "array" or (.requirements | length) != 1 then
      error("requirements must contain exactly one mapped dependency")
    else
      .requirements[0]
    end
    | capture("^(?<project>" + $project + ")==(?<version>[A-Za-z0-9][A-Za-z0-9._+-]*)$"; "i")
    | .version
  ' "$manifest"
}

# Emit local package version, source version, and source hash.
local_package_values() {
  local binding=$1 source_kind=$2 pypi_pname=$3
  awk -v binding="$binding" -v source_kind="$source_kind" -v pypi_pname="$pypi_pname" '
    function qval(line) {
      if (match(line, /"[^"]*"/)) return substr(line, RSTART + 1, RLENGTH - 2)
      return ""
    }
    $0 ~ "^[[:space:]]*" binding "[[:space:]]*=[[:space:]]*hapy\\.buildPythonPackage[[:space:]]*\\{" {
      package_seen = 1
      next
    }
    package_seen && !package_version && /^[[:space:]]*version[[:space:]]*=/ {
      package_version = qval($0)
      next
    }
    package_seen && !source_done && source_kind == "pypi" && /fetchPypi[[:space:]]*\{/ { source_seen = 1; next }
    package_seen && !source_done && source_kind == "github" && /fetchFromGitHub[[:space:]]*\{/ { source_seen = 1; next }
    source_seen && source_kind == "pypi" && /^[[:space:]]*pname[[:space:]]*=/ && qval($0) == pypi_pname {
      pname_seen = 1
      next
    }
    source_seen && source_kind == "github" && /^[[:space:]]*tag[[:space:]]*=/ {
      source_version = qval($0)
      next
    }
    pname_seen && !source_version && /^[[:space:]]*version[[:space:]]*=/ {
      source_version = qval($0)
      next
    }
    source_seen && /^[[:space:]]*hash[[:space:]]*=/ {
      print package_version "\t" source_version "\t" qval($0)
      exit
    }
  ' "$source_file"
}

# Fixture: <PyPI pname>-<version>.sri, containing one SRI sha256 hash.
pypi_hash() {
  local project=$1 version=$2 metadata url base32
  if [[ -n ${HA_REQUIREMENTS_PYPI_HASH_DIR:-} ]]; then
    cat "$HA_REQUIREMENTS_PYPI_HASH_DIR/${project}-${version}.sri"
    return
  fi

  metadata=$(new_tmp)
  curl --fail --location --silent --show-error \
    "https://pypi.org/pypi/$project/$version/json" >"$metadata"
  url=$(jq -er '
    [.urls[] | select(.packagetype == "sdist" and (.url | endswith(".tar.gz")))]
    | if length == 1 then .[0].url else error("expected one source tarball") end
  ' "$metadata")
  # fetchPypi uses fetchurl, so its fixed-output hash is of the source archive
  # itself (unlike fetchFromGitHub's unpacked-tree hash).
  base32=$(nix-prefetch-url --type sha256 "$url")
  nix hash convert --hash-algo sha256 --to sri "$base32"
}

rewrite_package() {
  local binding=$1 source_kind=$2 pypi_pname=$3 version=$4 hash=$5 rewritten
  rewritten=$(new_tmp)
  awk -v binding="$binding" -v source_kind="$source_kind" -v pypi_pname="$pypi_pname" -v version="$version" -v hash="$hash" '
    function set_value(name, value, indentation) {
      match($0, /^[[:space:]]*/)
      indentation = substr($0, 1, RLENGTH)
      $0 = indentation name " = \"" value "\";"
    }
    $0 ~ "^[[:space:]]*" binding "[[:space:]]*=[[:space:]]*hapy\\.buildPythonPackage[[:space:]]*\\{" {
      package_seen = 1
    }
    package_seen && !package_version && /^[[:space:]]*version[[:space:]]*=/ {
      set_value("version", version)
      package_version = 1
    }
    package_seen && !source_done && source_kind == "pypi" && /fetchPypi[[:space:]]*\{/ { source_seen = 1 }
    package_seen && !source_done && source_kind == "github" && /fetchFromGitHub[[:space:]]*\{/ { source_seen = 1 }
    source_seen && source_kind == "pypi" && /^[[:space:]]*pname[[:space:]]*=/ && $0 ~ "\"" pypi_pname "\"" {
      pname_seen = 1
    }
    pname_seen && !source_version && /^[[:space:]]*version[[:space:]]*=/ {
      set_value("version", version)
      source_version = 1
    }
    source_seen && source_kind == "github" && /^[[:space:]]*tag[[:space:]]*=/ {
      set_value("tag", "v" version)
      source_version = 1
    }
    source_seen && source_kind == "github" && /^[[:space:]]*hash[[:space:]]*=/ {
      source_seen = 0
      source_done = 1
    }
    pname_seen && source_kind == "pypi" && /^[[:space:]]*hash[[:space:]]*=/ {
      set_value("hash", hash)
      pname_seen = 0
      source_seen = 0
      source_done = 1
    }
    { print }
  ' "$source_file" >"$rewritten"
  cmp -s "$source_file" "$rewritten" || mv "$rewritten" "$source_file"
}

stale=0
for mapping in "${mappings[@]}"; do
  IFS='|' read -r owner_repo domain binding manifest_project source_kind pypi_project <<<"$mapping"
  owner=${owner_repo%%/*}
  repo=${owner_repo#*/}
  ref=$(component_ref "$owner" "$repo")
  [[ -n $ref ]] || {
    echo "reconcile-ha-component-requirements: no source pin for $owner_repo" >&2
    exit 1
  }

  manifest=$(component_manifest "$owner" "$repo" "$ref" "$domain")
  required_version=$(manifest_version "$manifest" "$manifest_project")
  IFS=$'\t' read -r package_version source_version recorded_hash < <(
    local_package_values "$binding" "$source_kind" "$pypi_project"
  )
  [[ -n ${package_version:-} && -n ${source_version:-} && -n ${recorded_hash:-} ]] || {
    echo "reconcile-ha-component-requirements: incomplete local $binding package" >&2
    exit 1
  }
  if [[ $source_kind == github ]]; then
    source_version=${source_version#v}
  fi
  [[ $package_version == "$source_version" ]] || {
    echo "reconcile-ha-component-requirements: local $binding versions disagree" >&2
    exit 1
  }
  [[ $package_version == "$required_version" ]] && continue

  if [[ $source_kind == pypi ]]; then
    replacement_hash=$(pypi_hash "$pypi_project" "$required_version")
    [[ $replacement_hash =~ ^sha256-[A-Za-z0-9+/=]+$ ]] || {
      echo "reconcile-ha-component-requirements: invalid PyPI hash for $pypi_project $required_version" >&2
      exit 1
    }
  else
    replacement_hash=$recorded_hash
  fi
  stale=1
  printf 'RECONCILE  %s: %s -> %s\n' "$binding" "$package_version" "$required_version" >&2
  if ! $check_only; then
    rewrite_package "$binding" "$source_kind" "$pypi_project" "$required_version" "$replacement_hash"
  fi
done

if $check_only && [[ $stale -eq 1 ]]; then
  exit 1
fi
