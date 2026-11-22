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
#      [A-Za-z0-9._/-], and uncommitted changes unless --message is given;
#   2. with --message, stages unstaged tracked changes under sops/ and in
#      .sops.yaml (refusing unstaged changes anywhere else; changes you staged
#      yourself are kept) and commits them;
#   3. refuses unless HEAD descends from the revision flake.lock pins now and
#      every file under sops/ that differs from it carries sops metadata;
#   4. pushes HEAD to origin's refs/heads/<branch> by explicit refspec, never
#      forced, setting the upstream (so a new branch's first push works and a
#      branch tracking origin/main does not push to main);
#   5. points flake.nix at ?ref=main (on main) or ?ref=<branch>&rev=<HEAD>,
#      runs `nix flake update nix-secrets`, and checks that the lock records
#      HEAD and that no other lock node changed.
#
# restore-main points flake.nix back at ?ref=main, runs
# `nix flake update nix-secrets` and checks the other lock nodes are intact;
# with --expect REV it also checks the new pin descends from REV.
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
[ -n "$nixos_dir" ] || nixos_dir=$(git rev-parse --show-toplevel)
nixos_dir=$(cd "$nixos_dir" && pwd)
flake_nix=$nixos_dir/flake.nix
flake_lock=$nixos_dir/flake.lock
[ -f "$flake_nix" ] && [ -f "$flake_lock" ] || die "no flake.nix/flake.lock in $nixos_dir"

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
  local new=$1 line tmp
  tmp=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $url_re ]]; then line="${BASH_REMATCH[1]}\"$new\";"; fi
    printf '%s\n' "$line"
  done <"$flake_nix" >"$tmp"
  cat "$tmp" >"$flake_nix"
  rm -f "$tmp"
}

lock_node() { jq -er '.nodes[.root].inputs["'"$input"'"]' "$flake_lock"; }
locked_field() { jq -r --arg n "$node" '.nodes[$n].locked.'"$1"' // ""' "$flake_lock"; }
other_nodes() { jq -S --arg n "$node" 'del(.nodes[$n])' "$flake_lock"; }

# Rewrite the input url, re-lock just that input, and check nothing else in
# the lock moved. Prints nothing; callers read the lock afterwards.
relock() {
  local url=$1 before after
  before=$(other_nodes)
  set_input_url "$url"
  say "nix flake update $input ($url)"
  (cd "$nixos_dir" && nix flake update "$input")
  node=$(lock_node) || die "flake.lock has no $input input after the update"
  after=$(other_nodes)
  [ "$before" = "$after" ] || die "flake.lock changed outside the $input node; inspect with git diff flake.lock"
}

base=$(input_base)
node=$(lock_node) || die "flake.lock has no $input input"
locked_rev=$(locked_field rev)
canonical="$base?ref=$main&shallow=1"

if [ "$mode" = restore-main ]; then
  if [ -n "$expect" ]; then
    [ -n "$secrets_dir" ] || die "--expect needs --secrets-dir to check ancestry"
    [ -d "$secrets_dir" ] || die "nix-secrets checkout not found: $secrets_dir"
  fi
  relock "$canonical"
  rev=$(locked_field rev)
  [ -n "$rev" ] || die "flake.lock records no $input rev"
  if [ -n "$expect" ]; then
    git -C "$secrets_dir" fetch --quiet "$remote" "$main"
    git -C "$secrets_dir" cat-file -e "$rev^{commit}" 2>/dev/null ||
      die "pinned $rev is not in $secrets_dir after fetching $remote/$main"
    git -C "$secrets_dir" merge-base --is-ancestor "$expect" "$rev" ||
      die "pinned $main $rev does not contain $expect (merged under a new hash? compare the trees before opening the PR)"
    say "pin contains $expect"
  fi
  say "pinned $input to $main at $rev (was ${locked_rev:-none})"
  exit 0
fi

# --- publish ---------------------------------------------------------------
[ -n "$secrets_dir" ] || die "--secrets-dir is required"
[ -d "$secrets_dir" ] || die "nix-secrets checkout not found: $secrets_dir (pass SECRETS_DIR=<checkout>)"
cd "$secrets_dir"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$secrets_dir is not a git checkout"
secrets_dir=$(git rev-parse --show-toplevel)
cd "$secrets_dir"
say "nix-secrets checkout: $secrets_dir"

branch=$(git symbolic-ref --quiet --short HEAD) || die "detached HEAD in $secrets_dir; check out a branch"
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "branch name '$branch' must match [A-Za-z0-9._/-]+ (it goes into the flake url)"

untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  printf '%s\n' "$untracked" >&2
  die "untracked files in $secrets_dir; git add the ones to publish (or remove them) and re-run"
fi

in_scope() { case $1 in .sops.yaml | sops/*) return 0 ;; *) return 1 ;; esac }

unstaged=$(git diff --name-only)
staged=$(git diff --cached --name-only)
if [ -n "$unstaged$staged" ]; then
  if [ -z "$message" ]; then
    git status --short >&2
    die "uncommitted changes in $secrets_dir; re-run with MSG=\"...\" to commit them"
  fi
  outside=""
  while IFS= read -r p; do
    [ -z "$p" ] || in_scope "$p" || outside+="$p"$'\n'
  done <<<"$unstaged"
  if [ -n "$outside" ]; then
    printf '%s' "$outside" >&2
    die "unstaged changes outside sops/ and .sops.yaml; commit, stage or restore them yourself"
  fi
fi

# The locked revision must be an ancestor: otherwise the pin would drop
# secrets that are already published (a stale branch or checkout).
if [ -n "$locked_rev" ]; then
  git cat-file -e "$locked_rev^{commit}" 2>/dev/null || git fetch --quiet "$remote"
  git cat-file -e "$locked_rev^{commit}" 2>/dev/null ||
    die "locked $input revision $locked_rev is not in $secrets_dir even after fetching $remote"
  git merge-base --is-ancestor "$locked_rev" HEAD ||
    die "$branch does not contain the locked $input revision $locked_rev; rebase it onto $remote/$main"
fi

if [ -n "$unstaged" ]; then
  while IFS= read -r p; do git add -- "$p"; done <<<"$unstaged"
fi

# Plaintext guard: everything under sops/ that differs from the lock (in
# commits or about to be committed) must be a sops-encrypted document.
plain=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case $p in sops/*) ;; *) continue ;; esac
  # No grep -q: an early exit would SIGPIPE git show and fail the pipeline.
  git show ":$p" | grep -E '^sops:|"sops":[[:space:]]*\{' >/dev/null || plain+="$p"$'\n'
done < <(git diff --cached --name-only --diff-filter=d ${locked_rev:+"$locked_rev"})
if [ -n "$plain" ]; then
  printf '%s' "$plain" >&2
  if [ -n "$unstaged" ]; then
    while IFS= read -r p; do git reset --quiet -- "$p"; done <<<"$unstaged"
  fi
  die "files under sops/ without sops metadata (plaintext?); encrypt them with sops first"
fi

if ! git diff --cached --quiet; then
  say "committing in nix-secrets on $branch: $message"
  git commit --quiet -m "$message"
elif [ -n "$message" ]; then
  say "nothing to commit; MSG ignored"
fi
head=$(git rev-parse HEAD)

say "pushing $head to $remote refs/heads/$branch"
git push --set-upstream "$remote" "HEAD:refs/heads/$branch"
pushed=$(git ls-remote "$remote" "refs/heads/$branch" | cut -f1)
[ "$pushed" = "$head" ] || die "$remote refs/heads/$branch is ${pushed:-missing}, expected $head"

if [ "$branch" = "$main" ]; then
  url=$canonical
else
  url="$base?ref=$branch&rev=$head&shallow=1"
fi
relock "$url"
rev=$(locked_field rev)
ref=$(locked_field ref)
[ "$rev" = "$head" ] || die "flake.lock pins $input at ${rev:-nothing}, expected $head ($remote/$branch moved?)"
[ -z "$ref" ] || [ "$ref" = "$branch" ] || die "flake.lock pins ref '$ref', expected '$branch'"

say "pinned $input to $branch at $head"
if [ "$branch" != "$main" ]; then
  echo "Temporary pin: before opening the NixOS PR, merge $branch into nix-secrets $main and"
  echo "run \`task secrets:pin-main EXPECT=$head\` (see docs/agents/secrets.md)."
fi
