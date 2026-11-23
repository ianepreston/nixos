#!/usr/bin/env python3
"""Offline checks for finish_child.py.

Git runs against disposable repositories whose "origin" is a local bare repo;
`gh` is a stub on PATH that records calls and keeps PRs in a JSON file. No
network, real GitHub account or host is involved.
"""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


CLI = Path(__file__).with_name("finish_child.py")
BRANCH = "docs/1-example"
ORIGIN = "git@github.com:ianepreston/nixos.git"

# Stands in for ssh so origin can be a real github.com URL: serves
# git-upload-pack/git-receive-pack for <host>:<path> from $STUB_GIT_ROOT/<path>.
SSH_STUB = r"""
import os, shlex, sys
host, command = sys.argv[-2], sys.argv[-1]
if host != "git@github.com":
    sys.exit("ssh stub: unexpected host " + host)
service, path = shlex.split(command)
os.execvp("git", ["git", service.removeprefix("git-"),
                  os.path.join(os.environ["STUB_GIT_ROOT"], path)])
"""

# PRs live in $STUB_PRS; headRefOid is read live from the bare repo, as GitHub
# would report it, unless a record pins one. Every call is logged with GH_HOST.
GH_STUB = r"""
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "GH_HOST": os.environ.get("GH_HOST")}) + "\n")
prs_file = os.environ["STUB_PRS"]
prs = json.load(open(prs_file)) if os.path.exists(prs_file) else []

def branch_sha(branch):
    found = subprocess.run(
        ["git", "--git-dir", os.environ["STUB_BARE"], "rev-parse", "refs/heads/" + branch],
        capture_output=True, text=True,
    )
    return found.stdout.strip() if found.returncode == 0 else ""

def full(pr):
    pr = {"headRefOid": branch_sha(pr["headRefName"]), **pr}
    return pr

if args[:2] == ["auth", "status"]:
    print("github.com")
    for name in os.environ.get("STUB_ACCOUNTS", "").split(","):
        print(f"  Logged in to github.com account {name} (keyring)")
        print(f"  - Active account: {str(name == os.environ['STUB_ACTIVE']).lower()}")
elif args[:2] == ["pr", "list"]:
    head = args[args.index("--head") + 1]
    print(json.dumps([full(pr) for pr in prs if pr["headRefName"] == head]))
elif args[:2] == ["pr", "view"]:
    print(json.dumps(full(next(pr for pr in prs if pr["url"] == args[2]))))
elif args[:2] == ["pr", "create"]:
    number = len(prs) + 1
    prs.append({
        "number": number,
        "url": f"https://github.example/pull/{number}",
        "state": "OPEN",
        "headRefName": args[args.index("--head") + 1],
        "baseRefName": args[args.index("--base") + 1],
        "isCrossRepository": False,
        "author": {"login": os.environ["STUB_ACTIVE"]},
        "body": open(args[args.index("--body-file") + 1]).read(),
    })
    json.dump(prs, open(prs_file, "w"))
    print(prs[-1]["url"])
elif args[0] == "api":
    sha = branch_sha(args[-3].split("/branches/", 1)[1])
    print(sha)
    sys.exit(0 if sha else 1)
else:
    sys.exit("gh stub: unexpected " + " ".join(args))
"""


class FinishChildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bare = self.root / "ianepreston" / "nixos.git"
        self.wt = self.root / "work tree"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f"#!{sys.executable}\n{GH_STUB}")
        gh.chmod(0o755)
        ssh = bin_dir / "ssh-stub"
        ssh.write_text(SSH_STUB)
        self.log = self.root / "gh.log"
        self.prs = self.root / "prs.json"
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            STUB_LOG=str(self.log),
            STUB_PRS=str(self.prs),
            STUB_BARE=str(self.bare),
            STUB_ACCOUNTS="work-account,ianepreston",
            STUB_ACTIVE="ianepreston",
            GH_HOST="enterprise.example",
            GIT_SSH_COMMAND=f"{shlex.quote(sys.executable)} {shlex.quote(str(ssh))}",
            GIT_SSH_VARIANT="simple",
            STUB_GIT_ROOT=str(self.root),
        )
        self.git("init", "--quiet", "--bare", "--initial-branch=main", str(self.bare))
        self.git("init", "--quiet", "--initial-branch=main", str(self.wt))
        self.wgit("config", "user.name", "Test")
        self.wgit("config", "user.email", "test@example.invalid")
        self.write("skills/a.md", "a\n")
        self.write("other.nix", "{ }\n")
        self.commit("base")
        self.wgit("remote", "add", "origin", ORIGIN)
        self.wgit("push", "--quiet", "origin", "main")
        self.base = self.head()
        self.wgit("checkout", "--quiet", "-b", BRANCH)
        self.message = self.root / "message.txt"
        self.message.write_text("docs: example change\n\nBody.\n")
        self.body = self.root / "body.md"
        self.body.write_text("Closes #1.\n\n## What\n\nExample.\n")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], check=True, capture_output=True, text=True, env=self.env
        ).stdout.strip()

    def wgit(self, *args):
        return self.git("-C", str(self.wt), *args)

    def write(self, path, text):
        target = self.wt / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, *messages):
        self.wgit("add", "--all")
        argv = ["commit", "--quiet", "--allow-empty"]
        for message in messages:
            argv += ["-m", message]
        self.wgit(*argv)

    def head(self, ref="HEAD"):
        return self.wgit("rev-parse", ref)

    def remote(self):
        process = subprocess.run(
            ["git", "--git-dir", str(self.bare), "rev-parse", f"refs/heads/{BRANCH}"],
            capture_output=True,
            text=True,
        )
        return process.stdout.strip() if process.returncode == 0 else None

    def calls(self, verb=None):
        if not self.log.exists():
            return []
        lines = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [line for line in lines if verb is None or line["args"][:2] == verb]

    def seed_pr(self, **overrides):
        pr = {
            "number": 7,
            "url": "https://github.example/pull/7",
            "state": "OPEN",
            "headRefName": BRANCH,
            "baseRefName": "main",
            "isCrossRepository": False,
            "author": {"login": "ianepreston"},
            "body": "Closes #1.\n",
            **overrides,
        }
        self.prs.write_text(json.dumps([pr]))

    def cli_args(self):
        return [
            sys.executable,
            str(CLI),
            "--worktree",
            str(self.wt),
            "--branch",
            BRANCH,
            "--base",
            self.base,
            "--allow",
            "skills/",
        ]

    def run_cli(self, *extra, ok=True, branch=BRANCH, base=None, pr=True):
        argv = [
            sys.executable,
            str(CLI),
            "--worktree",
            str(self.wt),
            "--branch",
            branch,
            "--base",
            base or self.base,
            "--allow",
            "skills/",
            "--message-file",
            str(self.message),
            *extra,
        ]
        if pr:
            argv += ["--title", "docs: example", "--body-file", str(self.body)]
        process = subprocess.run(argv, capture_output=True, text=True, env=self.env)
        self.assertEqual(process.returncode == 0, ok, process.stderr + process.stdout)
        return json.loads(process.stdout) if ok else process.stderr

    def assert_untouched(self):
        self.assertEqual(self.head(), self.base)
        self.assertIsNone(self.remote())
        self.assertEqual(self.calls(["pr", "create"]), [])

    # Happy paths and reconcile.

    def test_full_run_then_rerun_is_a_no_op(self):
        self.write("skills/a.md", "changed\n")
        self.write("skills/new dir/b.md", "new\n")
        first = self.run_cli()
        self.assertEqual(first["done"], ["commit", "push", "pr"])
        self.assertEqual(first["head"], self.remote())
        self.assertEqual(first["pr"], "https://github.example/pull/1")
        self.assertEqual(first["account"], "ianepreston")
        self.assertEqual(first["commits_since_base"], 1)
        message = self.wgit("log", "-1", "--format=%B")
        self.assertEqual(message, "docs: example change\n\nBody.")
        self.assertEqual(self.head("HEAD~1"), self.base)
        create = self.calls(["pr", "create"])[0]["args"]
        self.assertEqual(create[create.index("--base") + 1], "main")
        self.assertEqual(create[create.index("--head") + 1], BRANCH)

        second = self.run_cli()
        self.assertEqual(second["done"], [])
        self.assertEqual(second["skipped"], ["commit", "push", "pr"])
        self.assertEqual(second["head"], first["head"])
        self.assertEqual(len(self.calls(["pr", "create"])), 1)

    def test_child_committed_push_denied(self):
        self.write("skills/a.md", "changed\n")
        self.commit("docs: child commit")
        result = self.run_cli()
        self.assertEqual(result["done"], ["push", "pr"])
        self.assertEqual(result["skipped"], ["commit"])
        self.assertEqual(self.remote(), self.head())

    def test_already_pushed_only_opens_pr(self):
        self.write("skills/a.md", "changed\n")
        self.commit("docs: child commit")
        self.wgit("push", "--quiet", "origin", BRANCH)
        self.assertEqual(self.run_cli()["done"], ["pr"])

    def test_deletions_are_committed(self):
        (self.wt / "skills/a.md").unlink()
        self.run_cli()
        tree = self.wgit("ls-tree", "-r", "--name-only", "HEAD")
        self.assertNotIn("skills/a.md", tree.split())

    def test_existing_matching_pr_is_reused_and_head_verified(self):
        self.write("skills/a.md", "changed\n")
        self.seed_pr()
        result = self.run_cli()
        self.assertEqual(result["done"], ["commit", "push"])
        self.assertEqual(result["pr"], "https://github.example/pull/7")
        self.assertTrue(self.calls(["pr", "view"]))

    # Finding 1: allow-list coverage and glob semantics.

    def test_path_outside_allow_list_refused_before_any_action(self):
        self.write("skills/a.md", "changed\n")
        self.write("other.nix", "{ x = 1; }\n")
        self.assertIn("other.nix", self.run_cli(ok=False))
        self.assert_untouched()

    def test_committed_path_outside_allow_list_refused(self):
        self.write("other.nix", "{ x = 1; }\n")
        self.commit("child commit")
        self.assertIn("other.nix", self.run_cli(ok=False))
        self.assertIsNone(self.remote())

    def test_path_changed_then_reverted_in_child_commits_refused(self):
        self.write("other.nix", "{ x = 1; }\n")
        self.commit("child: touch other")
        self.write("other.nix", "{ }\n")
        self.write("skills/a.md", "changed\n")
        self.commit("child: revert other")
        self.assertEqual(self.wgit("diff", "--name-only", self.base), "skills/a.md")
        self.assertIn("other.nix", self.run_cli(ok=False))
        self.assertIsNone(self.remote())

    def test_staged_then_deleted_file_is_seen(self):
        self.write("secret.txt", "x\n")
        self.wgit("add", "secret.txt")
        (self.wt / "secret.txt").unlink()
        self.write("skills/a.md", "changed\n")
        self.assertIn("secret.txt", self.run_cli(ok=False))
        self.assert_untouched()

    def test_star_does_not_cross_slash(self):
        self.write("skills/a/b.md", "nested\n")
        argv = ["--allow", "skills/*.md"]
        process = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "--worktree",
                str(self.wt),
                "--branch",
                BRANCH,
                "--base",
                self.base,
                "--message-file",
                str(self.message),
                "--title",
                "t",
                "--body-file",
                str(self.body),
                *argv,
            ],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(process.returncode, 1, process.stdout)
        self.assertIn("skills/a/b.md", process.stderr)
        self.assert_untouched()
        (self.wt / "skills/a/b.md").unlink()
        self.write("skills/c.md", "flat\n")
        process = subprocess.run(
            process.args, capture_output=True, text=True, env=self.env
        )
        self.assertEqual(process.returncode, 0, process.stderr)

    # Finding 2: in-progress operations, merges, commit count.

    def test_in_progress_operation_refused(self):
        self.write("skills/a.md", "changed\n")
        git_dir = Path(self.wgit("rev-parse", "--absolute-git-dir"))
        for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD"):
            (git_dir / marker).write_text(self.base + "\n")
            self.assertIn(marker, self.run_cli(ok=False))
            (git_dir / marker).unlink()
        (git_dir / "rebase-merge").mkdir()
        self.assertIn("rebase-merge", self.run_cli(ok=False))
        self.assert_untouched()

    def test_merge_commit_since_base_refused(self):
        self.wgit("checkout", "--quiet", "-b", "side")
        self.write("skills/side.md", "side\n")
        self.commit("side")
        self.wgit("checkout", "--quiet", BRANCH)
        self.write("skills/a.md", "changed\n")
        self.commit("docs: change")
        self.wgit("merge", "--quiet", "--no-ff", "--no-edit", "side")
        self.assertIn("merge commits since base", self.run_cli(ok=False))
        self.assertIsNone(self.remote())

    def test_commit_count_reported(self):
        self.write("skills/a.md", "one\n")
        self.commit("docs: one")
        self.write("skills/a.md", "two\n")
        self.commit("docs: two")
        self.write("skills/a.md", "three\n")
        result = self.run_cli()
        self.assertEqual(result["commits_since_base"], 3)
        self.assertEqual(
            [commit["subject"] for commit in result["commits"]],
            ["docs: one", "docs: two", "docs: example change"],
        )
        self.assertEqual(result["commits"][-1]["sha"], result["head"])

    def test_unmerged_index_refused(self):
        self.write("skills/a.md", "stashed\n")
        self.wgit("stash", "--quiet")
        self.write("skills/a.md", "committed\n")
        self.commit("docs: conflicting")
        process = subprocess.run(
            ["git", "-C", str(self.wt), "stash", "pop"],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue(self.wgit("ls-files", "--unmerged"))
        self.assertIn("unmerged", self.run_cli(ok=False))
        self.assertEqual(self.head("HEAD~1"), self.base)
        self.assertIsNone(self.remote())

    def test_wrong_branch_and_base_refused(self):
        self.write("skills/a.md", "changed\n")
        self.assertIn(
            "expected docs/other", self.run_cli(ok=False, branch="docs/other")
        )
        other = self.root / "other"
        self.git("init", "--quiet", str(other))
        self.git(
            "-C",
            str(other),
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "unrelated",
        )
        self.wgit("fetch", "--quiet", str(other), "HEAD")
        unrelated = self.head("FETCH_HEAD")
        self.assertIn("does not descend", self.run_cli(ok=False, base=unrelated))
        self.assertIn("not a commit", self.run_cli(ok=False, base="0" * 40))
        self.assert_untouched()

    # Finding 3: push URL, refspec/tags, default-branch lookup fails closed.

    def test_protected_branch_refused(self):
        self.wgit("checkout", "--quiet", "main")
        self.write("skills/a.md", "changed\n")
        self.assertIn("protected", self.run_cli(ok=False, branch="main"))
        self.assertEqual(self.head(), self.base)

    def test_default_branch_refused_and_lookup_fails_closed(self):
        self.write("skills/a.md", "changed\n")
        bare = ("--git-dir", str(self.bare))
        self.git(*bare, "update-ref", f"refs/heads/{BRANCH}", self.base)
        self.git(*bare, "symbolic-ref", "HEAD", f"refs/heads/{BRANCH}")
        self.assertIn("protected/default", self.run_cli(ok=False))
        self.git(*bare, "update-ref", "-d", f"refs/heads/{BRANCH}")
        self.git("--git-dir", str(self.bare), "symbolic-ref", "HEAD", "refs/heads/gone")
        self.assertIn("default branch", self.run_cli(ok=False))
        self.assert_untouched()

    def test_push_url_mismatch_refused(self):
        self.write("skills/a.md", "changed\n")
        fork = "git@github.com:ianepreston/fork.git"
        self.wgit("remote", "set-url", "--push", "origin", fork)
        self.assertIn("differs from fetch URL", self.run_cli(ok=False))
        self.assert_untouched()

    def test_two_push_urls_refused(self):
        self.write("skills/a.md", "changed\n")
        self.wgit("remote", "set-url", "--add", "--push", "origin", ORIGIN)
        self.wgit("remote", "set-url", "--add", "--push", "origin", ORIGIN)
        self.assertIn("2 push URLs", self.run_cli(ok=False))
        self.assert_untouched()

    def test_other_host_or_inexact_path_refused(self):
        self.write("skills/a.md", "changed\n")
        for url in (
            "git@gitlab.example:ianepreston/nixos.git",
            "https://github.com.example/ianepreston/nixos.git",
            "ssh://git@mirror.example/github.com/ianepreston/nixos.git",
            "git@github.com:mirror/ianepreston/nixos.git",
        ):
            self.wgit("remote", "set-url", "origin", url)
            self.assertIn("is not github.com/ianepreston/nixos", self.run_cli(ok=False))
        self.assert_untouched()

    def test_remote_not_naming_repo_refused(self):
        self.write("skills/a.md", "changed\n")
        error = self.run_cli("--repo", "someone/else", ok=False)
        self.assertIn("is not github.com/someone/else", error)
        self.assert_untouched()

    def test_github_url_forms(self):
        spec = importlib.util.spec_from_file_location("finish_child", CLI)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for url in (
            "git@github.com:ianepreston/nixos.git",
            "ssh://git@github.com/ianepreston/nixos.git",
            "ssh://git@github.com:22/ianepreston/nixos",
            "https://github.com/ianepreston/nixos.git",
            "https://github.com/ianepreston/nixos",
        ):
            self.assertEqual(module.github_path(url), "ianepreston/nixos", url)
        for url in (
            "http://github.com/ianepreston/nixos.git",
            "git@example.com:ianepreston/nixos.git",
            "/srv/git/ianepreston/nixos.git",
        ):
            self.assertNotEqual(module.github_path(url), "ianepreston/nixos", url)

    def test_tags_are_not_pushed(self):
        self.write("skills/a.md", "changed\n")
        self.commit("docs: tagged")
        self.wgit("tag", "-a", "-m", "t", "v-test")
        self.wgit("config", "push.followTags", "true")
        self.run_cli()
        tags = self.git("--git-dir", str(self.bare), "tag", "--list")
        self.assertEqual(tags, "")
        self.assertEqual(self.remote(), self.head())

    def test_diverged_remote_is_not_force_pushed(self):
        self.write("skills/a.md", "one\n")
        self.commit("docs: one")
        self.wgit("push", "--quiet", "origin", BRANCH)
        pushed = self.head()
        self.wgit("reset", "--quiet", "--hard", self.base)
        self.write("skills/a.md", "two\n")
        self.assertIn("not an ancestor", self.run_cli(ok=False))
        self.assertEqual(self.remote(), pushed)

    # Finding 4: fixed account and github.com host.

    def test_wrong_gh_account_refused_before_commit(self):
        self.env["STUB_ACTIVE"] = "work-account"
        self.write("skills/a.md", "changed\n")
        error = self.run_cli(ok=False)
        self.assertIn("gh auth switch --hostname github.com --user ianepreston", error)
        self.assert_untouched()

    def test_account_flag_removed(self):
        self.write("skills/a.md", "changed\n")
        process = subprocess.run(
            [*self.cli_args(), "--account", "work-account"],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(process.returncode, 2)
        self.assertIn("unrecognized arguments: --account", process.stderr)

    def test_every_gh_call_targets_github_com(self):
        self.write("skills/a.md", "changed\n")
        self.run_cli()
        calls = self.calls()
        self.assertTrue(calls)
        for call in calls:
            self.assertEqual(call["GH_HOST"], "github.com", call)
            args = call["args"]
            if args[0] == "pr":
                self.assertEqual(
                    args[args.index("--repo") + 1], "github.com/ianepreston/nixos"
                )
            else:
                self.assertEqual(args[args.index("--hostname") + 1], "github.com")

    # Finding 5: existing PR reconcile.

    def test_mismatched_existing_pr_refused(self):
        self.write("skills/a.md", "changed\n")
        for override, text in (
            ({"baseRefName": "develop"}, "base branch"),
            ({"isCrossRepository": True}, "cross-repository"),
            ({"author": {"login": "work-account"}}, "author"),
        ):
            self.seed_pr(**override)
            self.assertIn(text, self.run_cli(ok=False))
        self.assert_untouched()

    def test_closed_or_multiple_prs_refused(self):
        self.write("skills/a.md", "changed\n")
        self.seed_pr(state="CLOSED")
        self.assertIn("(closed)", self.run_cli(ok=False))
        self.seed_pr()
        second = json.loads(self.prs.read_text())[0] | {"number": 8, "url": "u8"}
        self.prs.write_text(json.dumps(json.loads(self.prs.read_text()) + [second]))
        self.assertIn("u8 (open)", self.run_cli(ok=False))
        self.assert_untouched()

    def test_pr_head_mismatch_refused(self):
        self.write("skills/a.md", "changed\n")
        self.seed_pr(headRefOid="0" * 40)
        script = CLI.read_text().replace("PR_HEAD_ATTEMPTS = 5", "PR_HEAD_ATTEMPTS = 1")
        fast = self.root / "finish_child.py"
        fast.write_text(script)
        process = subprocess.run(
            [
                sys.executable,
                str(fast),
                "--worktree",
                str(self.wt),
                "--branch",
                BRANCH,
                "--base",
                self.base,
                "--allow",
                "skills/",
                "--message-file",
                str(self.message),
            ],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(process.returncode, 1, process.stdout)
        self.assertIn("!= local head", process.stderr)

    # Finding 6: attribution footers.

    def test_attribution_footers_refused_everywhere(self):
        footers = (
            "Co-authored-by: Bot <bot@example.invalid>",
            "  co-authored-by: Bot <bot@example.invalid>",
            "Generated with [Claude Code](https://example.invalid/claude-code)",
            "\N{ROBOT FACE} Generated with Codex",
            "Generated by Copilot",
            "Authored by Claude Code",
            "\N{ROBOT FACE} Cursor agent",
        )
        self.write("skills/a.md", "changed\n")
        for footer in footers:
            self.message.write_text(f"docs: x\n\n{footer}\n")
            self.assertIn("--message-file", self.run_cli(ok=False), footer)
        self.message.write_text("docs: x\n")
        for footer in footers:
            self.body.write_text(f"Closes #1.\n\n{footer}\n")
            self.assertIn("--body-file", self.run_cli(ok=False), footer)
        self.body.write_text("Closes #1.\n")
        for footer in footers:
            self.seed_pr(body=f"Closes #1.\n\n{footer}\n")
            self.assertIn("existing PR", self.run_cli(ok=False), footer)
        self.prs.unlink()
        self.assert_untouched()
        self.commit("docs: x", footers[5])
        self.assertIn("commit ", self.run_cli(ok=False))
        self.assertIsNone(self.remote())

    def test_prose_and_signed_off_by_allowed(self):
        prose = (
            "Generated by nixos-generate-config during bootstrap.\n"
            "The commit messages are written by the runner.\n"
            "This pull request and its description were written by a bot.\n"
            "The file is regenerated by nix fmt.\n"
            "Claude Code and Codex children share this packet.\n\n"
            "Signed-off-by: Test <t@example.invalid>\n"
        )
        self.write("skills/a.md", "changed\n")
        self.message.write_text("docs: x\n\n" + prose)
        self.body.write_text("Closes #1.\n\n" + prose)
        self.assertEqual(self.run_cli()["done"], ["commit", "push", "pr"])

    def test_missing_message_or_pr_fields(self):
        self.write("skills/a.md", "changed\n")
        argv = [
            sys.executable,
            str(CLI),
            "--worktree",
            str(self.wt),
            "--branch",
            BRANCH,
            "--base",
            self.base,
            "--allow",
            "skills/*.md",
        ]
        process = subprocess.run(argv, capture_output=True, text=True, env=self.env)
        self.assertIn("--message-file is required", process.stderr)
        self.assertIn("--title and --body-file", self.run_cli(ok=False, pr=False))
        self.assert_untouched()


if __name__ == "__main__":
    unittest.main()
