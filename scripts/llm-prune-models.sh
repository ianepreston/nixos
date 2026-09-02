#!/usr/bin/env bash
# Prune GGUFs from llama-server's model cache that this host is no longer
# configured to serve. Runs *on* the llama-cpp host as root; driven by
# `task llm:models:prune` (see taskfiles/llm.yaml), which pipes it to
# `sudo bash -s --`.
#
# Usage: llm-prune-models.sh <cache-dir> <port> <env-file> <apply> <name>...
#
# where each <name> is a configured model, in llama-server's own
# `<owner>/<repo>:<TAG>` form (i.e. an attribute name from
# `myLlamaCpp.models`).
#
# ## What decides "in use"
#
# The Nix config, cross-checked against the running router.
#
# That is a change from the pre-#519 script, which asked `/props` for the
# single `model_path` and kept only that. In router mode the server holds
# at most one model resident out of several configured, so "what is loaded
# right now" is no longer the keep-set — running the old logic against a
# two-model host would have deleted whichever model happened to be idle,
# several GB, silently.
#
# The server is still consulted, for two things that config alone can't
# tell us:
#
#   1. It has to answer at all, and every configured name has to appear in
#      its `/v1/models`. That proves the router is running *this* config
#      rather than an older generation — deleting weights on the strength
#      of a config the running service hasn't picked up yet is exactly the
#      failure this guards.
#   2. Any model currently loaded has its `model_path` fetched from
#      `/props?model=...`, and the prune aborts if that path is in the
#      doomed set. A belt-and-braces check on the matching below.
#
# ## Matching cache files to configured models
#
# Directory level is exact: a configured `owner/repo:TAG` lives in
# `models--owner--repo`, so the mapping is built forwards (name to
# directory) and any directory no configured name maps to is deleted
# whole. No parsing of directory names back into repo ids, which is
# ambiguous for a repo whose own name contains `--`.
#
# File level needs the quant tag, and that is derived here the same way
# llama.cpp derives it in `get_gguf_split_info` (common/download.cpp):
# strip `.gguf`, strip a trailing `-NNNNN-of-NNNNN` shard suffix, then take
# the last `[-.]([A-Za-z0-9_]+)` run and upper-case it. Deletion is
# allowlisted rather than denylisted — a file is removed only if its
# derived tag is one we know is superseded, so an unparseable or untagged
# filename survives.
#
# ## Cache layout
#
# Standard HuggingFace cache under <cache-dir>:
#
#   models--<owner>--<repo>/
#     refs/main                          -> revision id
#     snapshots/<rev>/<file>.gguf        -> symlink into ../../blobs/
#     blobs/<sha256>                     the actual bytes
#
# Bytes live in blobs/; everything in snapshots/ is a symlink. So the
# prune works by removing snapshot entries and then garbage-collecting
# blobs nothing points at any more.
set -euo pipefail

CACHE_DIR=${1:?cache dir}
PORT=${2:?port}
ENV_FILE=${3:?env file}
APPLY=${4:-false}
shift 4
CONFIGURED=("$@")

log() { printf '%s\n' "$*"; }

if [ ${#CONFIGURED[@]} -eq 0 ]; then
  log "[!] no configured models passed in. Refusing to prune — an empty"
  log "    keep-set would delete the entire cache."
  exit 1
fi

if [ ! -d "$CACHE_DIR" ]; then
  log "[!] no model cache at $CACHE_DIR — nothing to prune"
  exit 0
fi

api_key=$(grep -oP 'LLAMA_API_KEY=\K.*' "$ENV_FILE" 2>/dev/null || true)
api() {
  curl -sf --max-time 15 "http://127.0.0.1:${PORT}$1" \
    ${api_key:+-H "Authorization: Bearer ${api_key}"} 2>/dev/null || true
}

# --- confirm the router is running this config -----------------------------
models_json=$(api /v1/models)
if [ -z "$models_json" ]; then
  log "[!] llama-server on 127.0.0.1:${PORT} did not answer /v1/models."
  log "    Refusing to prune — an unreachable server is exactly the state"
  log "    where we know least. Check: systemctl status llama-cpp"
  exit 1
fi

for name in "${CONFIGURED[@]}"; do
  if ! printf '%s' "$models_json" | grep -qF "\"$name\""; then
    log "[!] configured model '$name' is not in the router's /v1/models."
    log "    The running service is on a different generation than the"
    log "    config this prune was derived from. Deploy first, then prune."
    exit 1
  fi
done

log "[+] router knows all ${#CONFIGURED[@]} configured model(s):"
for name in "${CONFIGURED[@]}"; do log "      $name"; done

# --- expected cache locations for the configured set -----------------------
# name -> repo dir basename, and the set of tags kept per repo dir.
declare -A keep_dir=()      # dir basename -> 1
declare -A keep_tags=()     # dir basename -> " TAG1 TAG2 "

for name in "${CONFIGURED[@]}"; do
  repo=${name%:*}
  tag=${name##*:}
  if [ "$repo" = "$name" ] || [ -z "$tag" ]; then
    log "[!] configured model '$name' has no ':<quant>' tag. Refusing to"
    log "    prune: llama.cpp derives its own tag for such a model and the"
    log "    cache entry would not be the one this name describes."
    exit 1
  fi
  dir="models--${repo//\//--}"
  tag=${tag^^}
  keep_dir[$dir]=1
  keep_tags[$dir]="${keep_tags[$dir]:-} $tag "
done

# --- collect what to remove ------------------------------------------------
declare -a doomed=()

# The same derivation llama.cpp uses; see the header.
derive_tag() {
  local n=${1%.gguf}
  n=$(printf '%s' "$n" | sed -E 's/-[0-9]{5}-of-[0-9]{5}$//')
  printf '%s' "$n" | sed -nE 's/.*[-.]([A-Za-z0-9_]+)$/\1/p' | tr '[:lower:]' '[:upper:]'
}

for d in "$CACHE_DIR"/models--*; do
  [ -d "$d" ] || continue
  base=$(basename "$d")

  # 1. Whole repos nothing configured maps to.
  if [ -z "${keep_dir[$base]:-}" ]; then
    doomed+=("$d")
    continue
  fi

  # 2. Superseded revisions of a kept repo. `refs/main` is the cache's own
  #    record of the current revision, so this needs no guessing.
  current_rev=$(cat "$d/refs/main" 2>/dev/null || true)
  if [ -z "$current_rev" ]; then
    log "    skip  $base — no refs/main, cannot tell which revision is current"
    continue
  fi
  for s in "$d"/snapshots/*; do
    [ -d "$s" ] || continue
    [ "$(basename "$s")" = "$current_rev" ] && continue
    doomed+=("$s")
  done

  # 3. Superseded quants inside the current revision. mmproj/mtp sidecars
  #    are never models in their own right (llama.cpp skips them when it
  #    enumerates the cache) and their own filenames carry an unrelated
  #    tag, so they are never matched here — they go only with their repo.
  for f in "$d/snapshots/$current_rev"/*.gguf; do
    [ -e "$f" ] || continue
    n=$(basename "$f")
    case "$n" in
      mmproj* | mtp-*) continue ;;
    esac
    t=$(derive_tag "$n")
    [ -n "$t" ] || continue
    case "${keep_tags[$base]}" in
      *" $t "*) continue ;;
    esac
    doomed+=("$f")
  done
done

# --- belt and braces: nothing loaded may be in the doomed set --------------
# Only a loaded model answers /props; an unloaded one 400s, which is fine —
# there is nothing to protect for a model that isn't resident.
for name in "${CONFIGURED[@]}"; do
  encoded=$(printf '%s' "$name" | sed -e 's|/|%2F|g' -e 's|:|%3A|g')
  live=$(api "/props?model=${encoded}&autoload=false" |
    grep -oP '"model_path"\s*:\s*"\K[^"]+' || true)
  [ -n "$live" ] || continue
  live=$(readlink -f "$live")
  for p in ${doomed[@]+"${doomed[@]}"}; do
    if [ "$live" = "$(readlink -f "$p")" ] || [ -z "${live##"$(readlink -f "$p")"/*}" ]; then
      log "[!] the prune would delete $p, which holds the currently loaded"
      log "    model $name ($live). Refusing — this is a bug in the matching"
      log "    above, not a stale cache."
      exit 1
    fi
  done
done

# --- apply -----------------------------------------------------------------
freed=0
size_of() { du -sb --dereference "$1" 2>/dev/null | cut -f1 || echo 0; }

if [ ${#doomed[@]} -eq 0 ]; then
  log "[+] nothing superseded — cache holds only the configured models"
else
  for p in "${doomed[@]}"; do
    sz=$(size_of "$p")
    freed=$((freed + sz))
    log "    $([ "$APPLY" = "true" ] && echo remove || echo "would remove") $(numfmt --to=iec --suffix=B "$sz" | tr -d ' ')	${p#"$CACHE_DIR"/}"
    [ "$APPLY" = "true" ] && rm -rf -- "$p"
  done
fi

# --- garbage-collect unreferenced blobs ------------------------------------
# A blob no surviving snapshot symlink points at can't be loaded by anything.
# This is what actually reclaims the space for the entries removed above,
# since those were symlinks. Only meaningful under APPLY (the dry run hasn't
# removed the symlinks yet, so nothing looks orphaned).
if [ "$APPLY" = "true" ]; then
  for repo in "$CACHE_DIR"/models--*; do
    [ -d "$repo/blobs" ] || continue
    referenced=$(find "$repo/snapshots" -type l -exec readlink -f {} \; 2>/dev/null | sort -u)
    for b in "$repo"/blobs/*; do
      [ -e "$b" ] || continue
      # A live download writes continuously; an hour of no writes means it
      # was interrupted.
      case "$b" in
        *.downloadInProgress)
          [ -n "$(find "$b" -mmin +60 2>/dev/null)" ] || continue
          ;;
        *)
          printf '%s\n' "$referenced" | grep -qxF "$(readlink -f "$b")" && continue
          ;;
      esac
      sz=$(size_of "$b")
      freed=$((freed + sz))
      log "    remove $(numfmt --to=iec --suffix=B "$sz" | tr -d ' ')	orphan blob $(basename "$b")"
      rm -f -- "$b"
    done
  done
fi

log ""
if [ "$APPLY" = "true" ]; then
  log "[+] freed $(numfmt --to=iec --suffix=B "$freed" | tr -d ' ')"
else
  log "[+] would free $(numfmt --to=iec --suffix=B "$freed" | tr -d ' ') — re-run with APPLY=true to delete"
fi
