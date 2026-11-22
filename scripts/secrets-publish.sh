#!/usr/bin/env bash
# Publish a nix-secrets commit and pin this flake's nix-secrets input to it
# (#1042). Behind `task secrets:publish` and `task secrets:pin-main`; see
# docs/agents/secrets.md for the workflow.
#
# usage:
#   secrets-publish.sh publish --secrets-dir DIR [--nixos-dir DIR] [--message MSG]
#   secrets-publish.sh restore-main [--nixos-dir DIR] [--secrets-dir DIR --expect REV]
#
# publish, in the nix-secrets checkout DIR (primary checkout or any linked
# worktree; HEAD must be a branch):
#   1. refuses untracked files, a detached HEAD, a branch name outside
#      [A-Za-z0-9._/-], a path with both staged and unstaged changes, any
#      change outside sops/ and .sops.yaml, and uncommitted changes unless
#      --message is given;
#   2. refuses unless HEAD descends from the revision flake.lock pins now;
#   3. with --message, stages the (wholly unstaged) changed files and commits;
#   4. plaintext guard: every sops/ file in the index and in every commit that
#      would be pushed must be a sops document whose every value outside the
#      `sops` block is an ENC[...] envelope, with no plaintext comments;
#   5. pushes HEAD to origin's refs/heads/<branch> by explicit refspec, never
#      forced, setting the upstream (so a new branch's first push works and a
#      branch tracking origin/main does not push to main);
#   6. points flake.nix at ?ref=main (on main) or ?ref=<branch>&rev=<HEAD>,
#      runs `nix flake update nix-secrets`, and checks the lock's locked and
#      original entries match that url and no other lock node changed.
#
# restore-main points flake.nix back at ?ref=main, runs
# `nix flake update nix-secrets` and checks the lock the same way; with
# --expect REV it first checks origin's main contains REV.
#
# On failure: flake.nix and flake.lock are always restored. The nix-secrets
# index is restored if the failure comes before the commit; after it, the
# commit stays (local until the push succeeds; pushed if only the pin fails)
# and the index matches it.
set -euo pipefail

die() {
  printf '\033[31m[!] %s\033[0m\n' "$*" >&2
  exit 1
}
say() { printf '\033[32m[+] %s\033[0m\n' "$*"; }

[ $# -ge 1 ] || die "usage: secrets-publish.sh publish|restore-main [options]"
mode=$1
shift
case $mode in publish | restore-main) ;; *) die "unknown mode: $mode" ;; esac

secrets_dir=""
nixos_dir=""
message=""
expect=""
while [ $# -gt 0 ]; do
  case $1 in
    --secrets-dir) secrets_dir=${2-} && shift 2 ;;
    --nixos-dir) nixos_dir=${2-} && shift 2 ;;
    --message) message=${2-} && shift 2 ;;
    --expect) expect=${2-} && shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

remote=origin
main=main
input=nix-secrets

command -v jq >/dev/null || die "jq is required"
command -v python3 >/dev/null || die "python3 is required"
[ -n "$nixos_dir" ] || nixos_dir=$(git rev-parse --show-toplevel)
nixos_dir=$(cd "$nixos_dir" && pwd)
flake_nix=$nixos_dir/flake.nix
flake_lock=$nixos_dir/flake.lock
[ -f "$flake_nix" ] && [ -f "$flake_lock" ] || die "no flake.nix/flake.lock in $nixos_dir"

# --- rollback ----------------------------------------------------------------
# $work holds snapshots. On any exit before keep_flake / keep_index is set,
# the snapshots are copied back over the live files.
work=$(mktemp -d)
flake_saved=false
keep_flake=false
index_path=""
keep_index=true
cleanup() {
  local status=$?
  if [ "$flake_saved" = true ] && [ "$keep_flake" != true ]; then
    cat "$work/flake.nix" >"$flake_nix"
    cat "$work/flake.lock" >"$flake_lock"
    printf '\033[33m[~] restored flake.nix and flake.lock\033[0m\n' >&2
  fi
  if [ -n "$index_path" ] && [ "$keep_index" != true ]; then
    cp "$work/index" "$index_path"
    printf '\033[33m[~] restored the nix-secrets index\033[0m\n' >&2
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

save_flake() {
  cp "$flake_nix" "$work/flake.nix"
  cp "$flake_lock" "$work/flake.lock"
  flake_saved=true
}

# --- flake.nix / flake.lock ----------------------------------------------------
# The single `url = "git+ssh://.../nix-secrets.git?..."` line in flake.nix.
url_re='^([[:space:]]*url = )"(git\+ssh://[^"?]*/nix-secrets\.git)(\?[^"]*)?";[[:space:]]*$'

input_base() {
  local line n=0 base=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $url_re ]]; then
      n=$((n + 1))
      base=${BASH_REMATCH[2]}
    fi
  done <"$flake_nix"
  [ "$n" -eq 1 ] || die "expected exactly one nix-secrets git+ssh url line in flake.nix, found $n"
  printf '%s\n' "$base"
}

set_input_url() {
  local new=$1 line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $url_re ]]; then line="${BASH_REMATCH[1]}\"$new\";"; fi
    printf '%s\n' "$line"
  done <"$flake_nix" >"$work/flake.nix.new"
  cat "$work/flake.nix.new" >"$flake_nix"
}

lock_node() { jq -er '.nodes[.root].inputs["'"$input"'"] | strings' "$flake_lock"; }
locked_rev() { jq -r --arg n "$node" '.nodes[$n].locked.rev // ""' "$flake_lock"; }
other_nodes() { jq -S --arg n "$node" 'del(.nodes[$n])' "$flake_lock"; }

# Rewrite the input url and re-lock just that input (callers have run
# save_flake). Fails if anything else in the lock moved.
relock() {
  local url=$1 before after
  before=$(other_nodes)
  set_input_url "$url"
  say "nix flake update $input ($url)"
  (cd "$nixos_dir" && nix flake update "$input") || die "nix flake update $input failed"
  node=$(lock_node) || die "flake.lock has no $input input after the update"
  after=$(other_nodes)
  [ "$before" = "$after" ] || die "flake.lock changed outside the $input node"
}

# The lock's locked and original entries must both describe the url flake.nix
# now declares (always `shallow=1`): type git, the same repo url, ref REF,
# shallow true, original.rev ORIG_REV (absent when empty), and locked.rev REV
# (any full sha when empty).
check_lock() {
  local ref=$1 orig_rev=$2 rev=$3
  jq -e --arg n "$node" --arg url "${base#git+}" --arg ref "$ref" \
    --arg orev "$orig_rev" --arg rev "$rev" '
    .nodes[$n] as $x
    | ($x.locked | type == "object") and ($x.original | type == "object")
    and $x.locked.type == "git" and $x.original.type == "git"
    and $x.locked.url == $url and $x.original.url == $url
    and $x.locked.ref == $ref and $x.original.ref == $ref
    and $x.locked.shallow == true and $x.original.shallow == true
    and ($x.locked.rev | type == "string" and test("^[0-9a-f]{40}$"))
    and ($rev == "" or $x.locked.rev == $rev)
    and (if $orev == "" then ($x.original | has("rev") | not) else $x.original.rev == $orev end)
  ' "$flake_lock" >/dev/null || {
    jq --arg n "$node" '.nodes[$n]' "$flake_lock" >&2
    die "flake.lock $input entry does not match ref=$ref${orig_rev:+ rev=$orig_rev}${rev:+ (expected locked rev $rev)}"
  }
}

base=$(input_base)
node=$(lock_node) || die "flake.lock has no $input input"
old_rev=$(locked_rev)
canonical="$base?ref=$main&shallow=1"

if [ "$mode" = restore-main ]; then
  if [ -n "$expect" ]; then
    [ -n "$secrets_dir" ] || die "--expect needs --secrets-dir to check ancestry"
    [ -d "$secrets_dir" ] || die "nix-secrets checkout not found: $secrets_dir"
    # Check before touching anything: origin's main must already contain it.
    git -C "$secrets_dir" fetch --quiet "$remote" "refs/heads/$main"
    tip=$(git -C "$secrets_dir" rev-parse FETCH_HEAD)
    git -C "$secrets_dir" merge-base --is-ancestor "$expect" "$tip" 2>/dev/null ||
      die "$remote/$main ($tip) does not contain $expect; merge the secrets branch first (or, after a squash/rebase merge, compare trees and omit EXPECT)"
  fi
  save_flake
  relock "$canonical"
  check_lock "$main" "" ""
  rev=$(locked_rev)
  if [ -n "$expect" ]; then
    git -C "$secrets_dir" cat-file -e "$rev^{commit}" 2>/dev/null ||
      git -C "$secrets_dir" fetch --quiet "$remote" "refs/heads/$main"
    git -C "$secrets_dir" merge-base --is-ancestor "$expect" "$rev" 2>/dev/null ||
      die "pinned $main $rev does not contain $expect"
    say "pin contains $expect"
  fi
  keep_flake=true
  say "pinned $input to $main at $rev (was ${old_rev:-none})"
  exit 0
fi

# --- publish -------------------------------------------------------------------
[ -n "$secrets_dir" ] || die "--secrets-dir is required"
[ -d "$secrets_dir" ] || die "nix-secrets checkout not found: $secrets_dir (pass SECRETS_DIR=<checkout>)"
case $(yq --version 2>&1 || true) in
  *mikefarah*) ;;
  *) die "yq (mikefarah/yq-go) is required for the plaintext guard; run inside nix develop" ;;
esac
cd "$secrets_dir"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$secrets_dir is not a git checkout"
secrets_dir=$(git rev-parse --show-toplevel)
cd "$secrets_dir"
say "nix-secrets checkout: $secrets_dir"

# Full ref, never --short: a same-named tag makes the short form ambiguous.
head_ref=$(git symbolic-ref -q HEAD) || die "detached HEAD in $secrets_dir; check out a branch"
case $head_ref in refs/heads/?*) ;; *) die "HEAD is $head_ref, not a branch" ;; esac
branch=${head_ref#refs/heads/}
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "branch name '$branch' must match [A-Za-z0-9._/-]+ (it goes into the flake url)"

# A merge, rebase, cherry-pick or revert in progress would add parents or
# rewrite commits behind the guard's back.
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD rebase-merge rebase-apply; do
  [ ! -e "$(git rev-parse --git-path "$state")" ] ||
    die "a merge/rebase/cherry-pick/revert is in progress in $secrets_dir ($state); finish or abort it first"
done

untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  printf '%s\n' "$untracked" >&2
  die "untracked files in $secrets_dir; git add the ones to publish (or remove them) and re-run"
fi

in_scope() { case $1 in .sops.yaml | sops/*) return 0 ;; *) return 1 ;; esac }

# Paths are always listed NUL-separated and without rename detection, so a
# rename shows up as its source (a deletion) and its destination.
unstaged=()
while IFS= read -r -d '' p; do unstaged+=("$p"); done < <(git diff --no-renames --name-only -z)
staged=()
while IFS= read -r -d '' p; do staged+=("$p"); done < <(git diff --cached --no-renames --name-only -z)
if [ $((${#unstaged[@]} + ${#staged[@]})) -gt 0 ] && [ -z "$message" ]; then
  git status --short >&2
  die "uncommitted changes in $secrets_dir; re-run with MSG=\"...\" to commit them"
fi
problems=""
for p in ${staged[@]+"${staged[@]}"}; do
  for q in ${unstaged[@]+"${unstaged[@]}"}; do
    [ "$p" != "$q" ] || problems+="$p (both staged and unstaged changes; stage or restore it fully)"$'\n'
  done
done
for p in ${unstaged[@]+"${unstaged[@]}"} ${staged[@]+"${staged[@]}"}; do
  in_scope "$p" || problems+="$p (outside sops/ and .sops.yaml; commit and push it yourself)"$'\n'
done
if [ -n "$problems" ]; then
  printf '%s' "$problems" >&2
  die "refusing to publish these changes"
fi

git fetch --quiet "$remote"
# The locked revision must be an ancestor: otherwise the pin would drop
# secrets that are already published (a stale branch or checkout).
if [ -n "$old_rev" ]; then
  git cat-file -e "$old_rev^{commit}" 2>/dev/null ||
    die "locked $input revision $old_rev is not in $secrets_dir even after fetching $remote"
  git merge-base --is-ancestor "$old_rev" HEAD ||
    die "$branch does not contain the locked $input revision $old_rev; rebase it onto $remote/$main"
fi

# From here until the commit the index may change; a failure puts the saved
# copy back.
index_path=$(git rev-parse --path-format=absolute --git-path index)
cp "$index_path" "$work/index"
keep_index=false
for p in ${unstaged[@]+"${unstaged[@]}"}; do git add -- "$p"; done

# --- plaintext guard ---
enc_re='^ENC\[AES256_GCM,data:[A-Za-z0-9+/=]*,iv:[A-Za-z0-9+/=]+,tag:[A-Za-z0-9+/=]+,type:[a-z]+\]$'
# Exit non-zero if a JSON document repeats a key in any object. yq-go keeps
# duplicate YAML keys in its JSON output, so this covers YAML too.
no_dup_keys='
import json, sys
def pairs(kv):
    keys = [k for k, _ in kv]
    if len(keys) != len(set(keys)):
        sys.exit(1)
    return dict(kv)
json.load(open(sys.argv[1]), object_pairs_hook=pairs)
'
# check_doc OBJECT PATH: OBJECT (`<commit>:<path>` or `:<path>`) is a sops
# document: one YAML/JSON object with no duplicate keys, a `sops` block
# carrying an encrypted mac, every other leaf an ENC[...] envelope or null
# (sops keeps null placeholders; they carry no data), and no comment that is
# not itself an encrypted `#ENC[...]`.
check_doc() {
  git show "$1" >"$work/doc"
  case $2 in
    *.yaml | *.yml)
      sed -E 's/#?ENC\[[^]]*\]//g' "$work/doc" >"$work/stripped"
      if grep '#' "$work/stripped" >/dev/null; then
        echo "plaintext comment"
        return 1
      fi
      yq -o=json -I=0 '.' "$work/doc" >"$work/json" 2>/dev/null || {
        echo "not valid YAML"
        return 1
      }
      ;;
    *.json) cp "$work/doc" "$work/json" ;;
    *)
      echo "not a .yaml/.json sops file"
      return 1
      ;;
  esac
  if [ "$(jq -s length "$work/json" 2>/dev/null)" != 1 ]; then
    echo "not a single YAML/JSON document"
    return 1
  fi
  python3 -I -c "$no_dup_keys" "$work/json" 2>/dev/null || {
    echo "duplicate keys"
    return 1
  }
  jq -e --arg re "$enc_re" '
    type == "object"
    and (.sops | type == "object")
    and ((.sops.mac // "") | type == "string" and test($re))
    and (del(.sops) | [paths(type != "object" and type != "array") as $p | getpath($p)]
         | all(. == null or (type == "string" and test($re))))
  ' "$work/json" >/dev/null 2>&1 || {
    echo "a value outside the sops block is not an ENC[...] envelope"
    return 1
  }
}

bad=""
# guard OBJECT PATH LABEL: scope for every path; content for live sops/ files.
guard() {
  local why
  if ! in_scope "$2"; then
    bad+="$3: $2 (outside sops/ and .sops.yaml)"$'\n'
  elif [[ $2 == sops/* ]] && git cat-file -e "$1" 2>/dev/null; then
    why=$(check_doc "$1" "$2") || bad+="$3: $2 ($why)"$'\n'
  fi
}
# Every commit the push would publish (all parents of merges): not on any
# $remote ref and not in the lock.
history_guard() {
  local c p
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    while IFS= read -r -d '' p; do
      guard "$c:$p" "$p" "${c:0:12}"
    done < <(git diff-tree -m -r --root --no-renames --no-commit-id --name-only -z "$c")
  done < <(git rev-list HEAD --not --remotes="$remote" ${old_rev:+"$old_rev"})
}
# Index: every path that differs from HEAD.
while IFS= read -r -d '' p; do
  guard ":$p" "$p" index
done < <(git diff --cached --no-renames --name-only -z)
history_guard
if [ -n "$bad" ]; then
  printf '%s' "$bad" >&2
  die "plaintext guard failed; encrypt with sops (or push non-secret changes yourself)"
fi

if ! git diff --cached --quiet; then
  say "committing in nix-secrets on $branch: $message"
  git commit --quiet -m "$message"
elif [ -n "$message" ]; then
  say "nothing to commit; MSG ignored"
fi
keep_index=true
head=$(git rev-parse HEAD)

# Re-check what is actually about to be pushed: a commit hook can change the
# committed tree after the checks above.
history_guard
if [ -n "$bad" ]; then
  printf '%s' "$bad" >&2
  die "plaintext guard failed on the new commit $head; nothing was pushed. The commit stays local: inspect it, then \`git reset --soft HEAD^\` to undo it"
fi

say "pushing $head to $remote refs/heads/$branch"
git push --set-upstream "$remote" "HEAD:refs/heads/$branch"
pushed=$(git ls-remote "$remote" "refs/heads/$branch" | awk -v r="refs/heads/$branch" '$2 == r { print $1 }')
[ "$pushed" = "$head" ] || die "$remote refs/heads/$branch is ${pushed:-missing}, expected $head"

save_flake
if [ "$branch" = "$main" ]; then
  relock "$canonical"
  check_lock "$main" "" "$head"
else
  relock "$base?ref=$branch&rev=$head&shallow=1"
  check_lock "$branch" "$head" "$head"
fi
keep_flake=true

say "pinned $input to $branch at $head"
if [ "$branch" != "$main" ]; then
  echo "Temporary pin: before opening the NixOS PR, merge $branch into nix-secrets $main and"
  echo "run \`task secrets:pin-main EXPECT=$head\` (see docs/agents/secrets.md)."
fi
