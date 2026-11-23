#!/usr/bin/env python3
"""Finish a child's denied commit/push/PR from the supervisor; never merges.

Reconciles first and performs only the outstanding steps, so a rerun is safe:
commit (only when the worktree has changes), push the task branch
(fast-forward only), open the PR (only when the branch has none). It then
verifies a clean tree and that the remote head equals the local head.

Refuses: a branch/base mismatch, a protected or default branch, a path
outside --allow, any Co-authored-by trailer, a diverged remote branch, a
closed/merged PR for the branch, or an active gh account other than
--account. Prints a JSON summary of what it did and skipped.
"""

import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess
import sys


PROTECTED = {"main", "master"}
TRAILER = re.compile(r"^\s*co-authored-by\s*:", re.IGNORECASE | re.MULTILINE)


class Refusal(Exception):
    pass


def run(*argv, cwd=None, check=True):
    env = dict(os.environ, GIT_LITERAL_PATHSPECS="1", GH_PROMPT_DISABLED="1")
    process = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    if check and process.returncode:
        detail = (process.stderr or process.stdout).strip()
        raise Refusal(f"`{' '.join(argv[:3])} …` failed: {detail}")
    return process


def git(worktree, *argv, check=True):
    return run("git", "-C", str(worktree), *argv, check=check)


def paths_z(output):
    return {path for path in output.split("\0") if path}


def allowed(path, patterns):
    return any(
        path.startswith(pattern)
        if pattern.endswith("/")
        else fnmatchcase(path, pattern)
        for pattern in patterns
    )


def active_account(hostname):
    status = run("gh", "auth", "status", "--hostname", hostname, check=False)
    account = None
    for line in (status.stdout + status.stderr).splitlines():
        found = re.search(r"Logged in to \S+ account (\S+)", line)
        if found:
            account = found.group(1)
        elif account and re.search(r"Active account:\s*true", line):
            return account
    return None


def check_worktree(args):
    worktree = Path(args.worktree).resolve()
    top = git(worktree, "rev-parse", "--show-toplevel").stdout.strip()
    if Path(top).resolve() != worktree:
        raise Refusal(f"{worktree} is not a worktree root ({top})")
    branch = git(worktree, "symbolic-ref", "--short", "HEAD", check=False)
    if branch.returncode or branch.stdout.strip() != args.branch:
        found = branch.stdout.strip() or "detached HEAD"
        raise Refusal(f"checked-out branch is {found}, expected {args.branch}")
    default = git(worktree, "ls-remote", "--symref", args.remote, "HEAD", check=False)
    match = re.search(r"^ref: refs/heads/(\S+)\s+HEAD", default.stdout, re.MULTILINE)
    if args.branch in PROTECTED or (match and match.group(1) == args.branch):
        raise Refusal(f"refusing protected/default branch {args.branch}")
    base = git(
        worktree, "rev-parse", "--verify", f"{args.base}^{{commit}}", check=False
    )
    if base.returncode:
        raise Refusal(f"base {args.base} is not a commit in this repository")
    base = base.stdout.strip()
    if not base.startswith(args.base.lower()):
        raise Refusal(f"base {args.base} resolved to {base}; pass a SHA")
    if git(
        worktree, "merge-base", "--is-ancestor", base, "HEAD", check=False
    ).returncode:
        raise Refusal(f"HEAD does not descend from base {base}")
    return worktree, base


def changed_paths(worktree, base):
    committed = paths_z(
        git(worktree, "diff", "--no-renames", "--name-only", "-z", base, "HEAD").stdout
    )
    dirty = paths_z(
        git(worktree, "diff", "--no-renames", "--name-only", "-z", "HEAD").stdout
    ) | paths_z(
        git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout
    )
    return committed, dirty


def check_trailers(worktree, base, message):
    bodies = git(worktree, "log", "--format=%H%n%B%x00", f"{base}..HEAD").stdout
    for entry in filter(str.strip, bodies.split("\0")):
        sha, _, body = entry.strip().partition("\n")
        if TRAILER.search(body):
            raise Refusal(
                f"commit {sha} carries a Co-authored-by trailer; the repo wants "
                "none. Fix it by hand (unpushed) before rerunning."
            )
    if message is not None and TRAILER.search(message):
        raise Refusal("commit message contains a Co-authored-by trailer")


def remote_head(worktree, remote, branch):
    listed = git(worktree, "ls-remote", "--heads", remote, f"refs/heads/{branch}")
    return listed.stdout.split()[0] if listed.stdout.strip() else None


def finish(args):
    done, skipped = [], []
    worktree, base = check_worktree(args)
    account = active_account(args.hostname)
    if account != args.account:
        raise Refusal(
            f"active gh account is {account or 'unknown'}, expected {args.account}; "
            f"run `gh auth switch --hostname {args.hostname} --user {args.account}`"
        )
    committed, dirty = changed_paths(worktree, base)
    outside = sorted(p for p in committed | dirty if not allowed(p, args.allow))
    if outside:
        raise Refusal("paths outside --allow: " + ", ".join(outside))

    message = Path(args.message_file).read_text() if args.message_file else None
    check_trailers(worktree, base, message)
    if dirty and message is None:
        raise Refusal("worktree has changes; --message-file is required")

    # Everything that can refuse is checked before the first mutation; a new
    # commit only adds descendants, so an ancestor of HEAD stays one.
    remote = remote_head(worktree, args.remote, args.branch)
    if remote and (
        git(worktree, "cat-file", "-e", f"{remote}^{{commit}}", check=False).returncode
        or git(
            worktree, "merge-base", "--is-ancestor", remote, "HEAD", check=False
        ).returncode
    ):
        raise Refusal(f"remote {args.branch} at {remote} is not an ancestor of HEAD")
    prs = json.loads(
        run(
            "gh",
            "pr",
            "list",
            "--repo",
            args.repo,
            "--head",
            args.branch,
            "--state",
            "all",
            "--json",
            "number,url,state",
        ).stdout
        or "[]"
    )
    open_prs = [pr for pr in prs if pr["state"] == "OPEN"]
    if not open_prs:
        if prs:
            raise Refusal(
                f"branch already has a {prs[0]['state'].lower()} PR: {prs[0]['url']}"
            )
        if not (args.title and args.body_file):
            raise Refusal("no PR yet; --title and --body-file are required")
        if TRAILER.search(Path(args.body_file).read_text()):
            raise Refusal("PR body contains a Co-authored-by line")

    if dirty:
        git(worktree, "add", "--all", "--", *sorted(dirty))
        git(
            worktree,
            "commit",
            "--quiet",
            "--file",
            str(Path(args.message_file).resolve()),
        )
        check_trailers(worktree, base, None)
        done.append("commit")
    else:
        skipped.append("commit")
    head = git(worktree, "rev-parse", "HEAD").stdout.strip()
    if head == base:
        raise Refusal("nothing to publish: HEAD equals base and the tree is clean")

    if remote == head:
        skipped.append("push")
    else:
        git(
            worktree, "push", "--quiet", args.remote, f"{head}:refs/heads/{args.branch}"
        )
        done.append("push")

    if open_prs:
        url = open_prs[0]["url"]
        skipped.append("pr")
    else:
        created = run(
            "gh",
            "pr",
            "create",
            "--repo",
            args.repo,
            "--base",
            args.pr_base,
            "--head",
            args.branch,
            "--title",
            args.title,
            "--body-file",
            str(Path(args.body_file).resolve()),
        )
        url = created.stdout.strip().splitlines()[-1]
        done.append("pr")

    status = git(worktree, "status", "--porcelain", "--untracked-files=all").stdout
    if status.strip():
        raise Refusal("worktree is not clean after commit:\n" + status)
    published = run(
        "gh", "api", f"repos/{args.repo}/branches/{args.branch}", "--jq", ".commit.sha"
    ).stdout.strip()
    if published != head or remote_head(worktree, args.remote, args.branch) != head:
        raise Refusal(f"remote head {published or 'missing'} != local head {head}")
    return {
        "head": head,
        "pr": url,
        "account": account,
        "done": done,
        "skipped": skipped,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--base", required=True, help="packet base SHA")
    parser.add_argument(
        "--allow",
        action="append",
        required=True,
        help="permitted path glob, or directory prefix ending in /; repeatable",
    )
    parser.add_argument("--message-file", help="commit message; no trailer")
    parser.add_argument("--title")
    parser.add_argument("--body-file")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--repo", default="ianepreston/nixos")
    parser.add_argument("--pr-base", default="main")
    parser.add_argument("--account", default="ianepreston")
    parser.add_argument("--hostname", default="github.com")
    args = parser.parse_args()
    try:
        print(json.dumps(finish(args), indent=2))
    except (Refusal, OSError) as error:
        print(f"finish_child: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
