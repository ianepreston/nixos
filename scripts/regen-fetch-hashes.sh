#!/usr/bin/env bash
# Regenerate the fetch hashes Renovate can't maintain.
#
# Driven by `task hashes` locally and by
# .github/workflows/renovate-hashes.yml on every `renovate/**` branch, which
# commits whatever this script rewrites. See #625 for the failure it exists to
# prevent.
#
# Usage: regen-fetch-hashes.sh [--check] [file...]
#
#   --check   report what would change and exit 1 instead of rewriting.
#   file...   limit the scan to these files (default: every tracked *.nix).
#
# Extra flags for the `nix build` in mechanism 2 below come from the
# REGEN_NIX_ARGS environment variable (the Taskfile passes the usual
# `--override-input nix-secrets path:../nix-secrets`).
#
# ## Why this is needed
#
# Renovate's custom managers rewrite a version/tag/rev and nothing else. The
# `hash` beside it is a fixed-output derivation's *declared* content address,
# which Renovate has no way to compute — so it stays whatever it was. Nothing
# downstream necessarily notices: a rev-only change leaves the FOD's output
# path byte-identical to one already in the store, so nix skips the fetch
# entirely and builds the *old* source. That is how ha_blueair v1.56.4 merged
# green and ran v1.56.3 code on two hosts for two months (#606, fixed in
# #622) — the CI runner is hpp-1, whose warm store always holds the stale
# path, so only a cold store ever fails.
#
# Regenerating the hash here makes it correct by construction rather than
# merely loud.
#
# ## Two mechanisms
#
# 1. `fetchFromGitHub` blocks, found structurally — no marker needed. The
#    hash is the NAR hash of the unpacked `archive/<ref>.tar.gz`, which
#    `nix-prefetch-url --unpack` reproduces exactly, so these cost one
#    tarball download and no build.
#
# 2. A `# regen-hash: <flake attr>` marker on the line directly above a
#    `hash = "sha256-…";`, for hashes that are only knowable by building —
#    vendored dependency trees (`pkgs.caddy.withPlugins`, cargoHash,
#    npmDepsHash). There is no URL to prefetch, so the hash is read out of
#    nix itself: swap in `lib.fakeHash`, build, and take the `got:` line from
#    the mismatch error. The marker carries the attribute to build because
#    nothing in the file says where in the flake the derivation is reachable;
#    a new vendor-hash pin adds one comment line and is covered from then on.
#
#    This costs a real (network) FOD build every run, whether or not the hash
#    turns out to be stale — the whole point is that the recorded hash cannot
#    be trusted to tell us. Keep the file list scoped (CI passes only the
#    files the branch touched) so this only fires when the pin actually moved.
#
# Deliberately out of scope: `fetchPypi` (blueair-api). Its version is an `==`
# constraint from the component's own manifest.json, enforced at build time by
# manifestRequirementsCheckHook — a wrong pin there fails loudly, which is the
# property this script is trying to buy everywhere else.
set -euo pipefail

fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
hash_re='sha256-[A-Za-z0-9+/=]\+'

check_only=false
files=()

for arg in "$@"; do
  case "$arg" in
    --check) check_only=true ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    -*)
      echo "regen-fetch-hashes: unknown flag $arg" >&2
      exit 2
      ;;
    *) files+=("$arg") ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  mapfile -t files < <(git ls-files '*.nix')
fi

read -r -a nix_args <<<"${REGEN_NIX_ARGS:-}"

stale=0

# Mechanism 2 edits a file before building it. Whatever happens next —
# a failed build, a Ctrl-C halfway through one — the original has to come
# back: a fake hash must never survive this script.
backup_copy=""
backup_of=""

restore_backup() {
  [[ -n $backup_copy ]] || return 0
  cp "$backup_copy" "$backup_of"
  rm -f "$backup_copy"
  backup_copy=""
}
trap restore_backup EXIT INT TERM

note() { printf '%s\n' "$*" >&2; }

# Rewrite the hash on one line of one file, in place.
set_hash() {
  local file=$1 lineno=$2 new=$3
  sed -i "${lineno}s|${hash_re}|${new}|" "$file"
}

report() {
  local file=$1 lineno=$2 what=$3 old=$4 new=$5
  stale=1
  if $check_only; then
    note "STALE  $file:$lineno  $what"
    note "         recorded $old"
    note "         actual   $new"
  else
    note "FIXED  $file:$lineno  $what"
    note "         was $old"
    note "         now $new"
  fi
}

# --- mechanism 1: fetchFromGitHub ------------------------------------------
#
# Emits one tab-separated record per block: hash line number, owner, repo,
# ref, recorded hash, and any attribute that would make the plain archive
# tarball the wrong thing to hash.
parse_github_blocks() {
  awk '
    function qval(line) {
      if (match(line, /"[^"]*"/)) return substr(line, RSTART + 1, RLENGTH - 2)
      return ""
    }
    /fetchFromGitHub[ \t]*\{/ {
      inblock = 1; owner = ""; repo = ""; ref = ""; hash = ""; hashline = 0; caveats = ""
      next
    }
    inblock && /^[ \t]*owner[ \t]*=/ { owner = qval($0) }
    inblock && /^[ \t]*repo[ \t]*=/ { repo = qval($0) }
    inblock && /^[ \t]*(rev|tag)[ \t]*=/ { ref = qval($0) }
    inblock && /^[ \t]*hash[ \t]*=/ { hash = qval($0); hashline = FNR }
    inblock && /^[ \t]*(fetchSubmodules|leaveDotGit|deepClone|sparseCheckout|forceFetchGit)[ \t]*=/ {
      caveats = caveats " " $1
    }
    inblock && /^[ \t]*\}/ {
      printf "%d\t%s\t%s\t%s\t%s\t%s\n", hashline, owner, repo, ref, hash, caveats
      inblock = 0
    }
  ' "$1"
}

regen_github_src() {
  local file=$1 lineno owner repo ref old caveats url base32 new

  while IFS=$'\t' read -r lineno owner repo ref old caveats; do
    if [[ -n $caveats ]]; then
      note "SKIP   $file: $owner/$repo pins${caveats}, which the archive tarball doesn't reproduce"
      continue
    fi
    if [[ -z $owner || -z $repo || -z $ref || -z $old || $lineno -eq 0 ]]; then
      note "SKIP   $file: incomplete fetchFromGitHub block near line ${lineno:-?}"
      continue
    fi

    url="https://github.com/$owner/$repo/archive/$ref.tar.gz"
    base32=$(nix-prefetch-url --unpack --type sha256 "$url")
    new=$(nix hash convert --hash-algo sha256 --to sri "$base32")

    [[ $new == "$old" ]] && continue
    report "$file" "$lineno" "$owner/$repo@$ref" "$old" "$new"
    $check_only || set_hash "$file" "$lineno" "$new"
  done < <(parse_github_blocks "$file")
}

# --- mechanism 2: `# regen-hash: <flake attr>` ------------------------------
regen_marked_hash() {
  local file=$1 markerline attr lineno old out new

  # The marker has to be a comment line of its own, so prose that merely
  # mentions one doesn't trip this.
  while IFS=: read -r markerline _; do
    attr=$(sed -n "${markerline}s/.*regen-hash:[[:space:]]*//p" "$file")
    lineno=$((markerline + 1))
    old=$(sed -n "${lineno}p" "$file" | grep -o "$hash_re" || true)
    if [[ -z $attr || -z $old ]]; then
      note "regen-fetch-hashes: $file:$markerline marker needs a flake attr and a hash on the next line"
      exit 1
    fi

    # Build with a hash nothing can match, so nix has to run the fetcher and
    # report what the real one is.
    backup_of=$file
    backup_copy=$(mktemp)
    cp "$file" "$backup_copy"
    set_hash "$file" "$lineno" "$fake_hash"
    out=$(nix build --no-link "${nix_args[@]}" ".#$attr" 2>&1) && {
      note "regen-fetch-hashes: $attr built with a fake hash — is $file:$lineno actually its hash?"
      exit 1
    }
    restore_backup

    new=$(grep -o "got:[[:space:]]*$hash_re" <<<"$out" | tail -1 | grep -o "$hash_re" || true)
    if [[ -z $new ]]; then
      note "regen-fetch-hashes: no hash mismatch in the build of $attr:"
      note "$out"
      exit 1
    fi

    [[ $new == "$old" ]] && continue
    report "$file" "$lineno" "$attr" "$old" "$new"
    $check_only || set_hash "$file" "$lineno" "$new"
  done < <(grep -n '^[[:space:]]*#[[:space:]]*regen-hash:' "$file" || true)
}

for file in "${files[@]}"; do
  [[ -f $file ]] || continue
  regen_github_src "$file"
  regen_marked_hash "$file"
done

if $check_only && [[ $stale -eq 1 ]]; then
  exit 1
fi
exit 0
