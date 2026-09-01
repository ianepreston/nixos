#!/usr/bin/env bash
# Prune GGUFs from llama-server's model cache that the running server
# isn't using. Runs *on* the llama-cpp host as root; driven by
# `task llm:models:prune` (see taskfiles/llm.yaml), which pipes it to
# `sudo bash -s --`.
#
# Usage: llm-prune-models.sh <cache-dir> <port> <env-file> <apply:true|false>
#
# ## What decides "in use"
#
# The running llama-server, via `GET /props` -> `model_path`. Not the
# Nix config, and not a reimplementation of llama.cpp's `-hf` tag
# matching — that matching involves a case-insensitive regex, multi-shard
# split groups and mmproj sidecars (see find_best_model / get_split_files
# in common/download.cpp), and getting it subtly wrong here deletes a
# 9 GB blob that is actually live. Asking the server removes the guess.
#
# `/props` answers while the server is asleep (it doesn't reload the
# model to reply), so the idle-eviction window doesn't block a prune.
# If it doesn't answer at all we abort rather than fall back to a guess:
# an unreachable server is exactly the state where we know least.
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

log() { printf '%s\n' "$*"; }

if [ ! -d "$CACHE_DIR" ]; then
  log "[!] no model cache at $CACHE_DIR — nothing to prune"
  exit 0
fi

# --- resolve the live model ------------------------------------------------
api_key=$(grep -oP 'LLAMA_API_KEY=\K.*' "$ENV_FILE" 2>/dev/null || true)
props=$(curl -sf --max-time 15 "http://127.0.0.1:${PORT}/props" \
  ${api_key:+-H "Authorization: Bearer ${api_key}"} 2>/dev/null || true)
live_path=$(printf '%s' "$props" | grep -oP '"model_path"\s*:\s*"\K[^"]+' || true)

if [ -z "$live_path" ]; then
  log "[!] could not read model_path from llama-server on 127.0.0.1:${PORT}."
  log "    Refusing to prune — without knowing which model is live this"
  log "    would be guesswork. Check: systemctl status llama-cpp"
  exit 1
fi

# /props reports the service's own view (/var/lib/llama-cpp/...), which is a
# symlink to private/llama-cpp. Resolve that prefix so the paths line up with
# what globbing $CACHE_DIR produces — but resolve the *directory* only. The
# snapshot entry itself is a symlink into blobs/, and following it lands on
# the blob, which would make live_snapshot look like blobs/ and the repo dir
# look like the cache root. (It did: the first dry run of this script duly
# offered to delete the live model.)
live_snapshot=$(readlink -f "$(dirname "$live_path")")
live_file=$(basename "$live_path")
live_path="$live_snapshot/$live_file"
live_repo_dir=$(readlink -f "$live_snapshot/../..")

# Belt and braces on the above: if the live model didn't resolve to a file
# inside a models--*/snapshots/<rev>/ directory then our idea of the cache
# layout is wrong, and every comparison below is meaningless. Stop.
case "$live_repo_dir" in
  "$(readlink -f "$CACHE_DIR")"/models--*) ;;
  *)
    log "[!] live model resolved to $live_path"
    log "    which is not under a models--*/snapshots/<rev>/ path in $CACHE_DIR."
    log "    Refusing to prune against a cache layout this script doesn't understand."
    exit 1
    ;;
esac
[ -e "$live_path" ] || { log "[!] live model $live_path does not exist — refusing to prune"; exit 1; }

log "[+] live model: $live_file"
log "    repo: $(basename "$live_repo_dir")"

# Split models are <base>-00001-of-000NN.gguf and every shard is needed;
# multimodal projectors ride along as mmproj*.gguf. Keep the whole group.
split_base=$(printf '%s' "$live_file" | sed -E 's/-[0-9]{5}-of-[0-9]{5}\.gguf$//')

# --- collect what to remove ------------------------------------------------
declare -a doomed=()

# 1. Whole repos that aren't the live one.
for d in "$CACHE_DIR"/models--*; do
  [ -d "$d" ] || continue
  [ "$(readlink -f "$d")" = "$live_repo_dir" ] && continue
  doomed+=("$d")
done

# 2. Superseded revisions of the live repo.
for s in "$live_repo_dir"/snapshots/*; do
  [ -d "$s" ] || continue
  [ "$(readlink -f "$s")" = "$(readlink -f "$live_snapshot")" ] && continue
  doomed+=("$s")
done

# 3. Other quants sitting in the live snapshot. Non-.gguf files (configs,
#    tokenizer json) are kept — they're kilobytes and may be read at load.
for f in "$live_snapshot"/*.gguf; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  [ "$n" = "$live_file" ] && continue
  [[ $n == "$split_base"-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9].gguf ]] && continue
  [[ $n == mmproj* ]] && continue
  doomed+=("$f")
done

# --- apply -----------------------------------------------------------------
freed=0
size_of() { du -sb --dereference "$1" 2>/dev/null | cut -f1 || echo 0; }

if [ ${#doomed[@]} -eq 0 ]; then
  log "[+] nothing superseded — cache holds only the live model"
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
      # was interrupted. (/props answering already implies no download for
      # the live model is in flight, but this keeps the rule independent.)
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
