#!/usr/bin/env python3
"""Offline checks for finish_child.py.

Git runs against disposable repositories whose "origin" is a local bare repo;
`gh` is a stub on PATH that records calls and keeps PRs in a JSON file. No
network, real GitHub account or host is involved.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CLI = Path(__file__).with_name("finish_child.py")
BRANCH = "docs/1-example"

GH_STUB = r"""
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
prs_file = os.environ["STUB_PRS"]
prs = json.load(open(prs_file)) if os.path.exists(prs_file) else []
if args[:2] == ["auth", "status"]:
    print("github.com")
    for name in os.environ.get("STUB_ACCOUNTS", "").split(","):
        print(f"  Logged in to github.com account {name} (keyring)")
        print(f"  - Active account: {str(name == os.environ['STUB_ACTIVE']).lower()}")
elif args[:2] == ["pr", "list"]:
    head = args[args.index("--head") + 1]
    print(json.dumps([pr for pr in prs if pr["head"] == head]))
elif args[:2] == ["pr", "create"]:
    number = len(prs) + 1
    url = f"https://github.example/pull/{number}"
    head = args[args.index("--head") + 1]
    prs.append({"number": number, "url": url, "state": "OPEN", "head": head})
    json.dump(prs, open(prs_file, "w"))
    print(url)
elif args[0] == "api":
    branch = args[1].split("/branches/", 1)[1]
    sys.exit(subprocess.run(
        ["git", "--git-dir", os.environ["STUB_BARE"], "rev-parse", "refs/heads/" + branch]
    ).returncode)
else:
    sys.exit("gh stub: unexpected " + " ".join(args))
"""


class FinishChildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bare = self.root / "origin.git"
        self.wt = self.root / "work tree"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f"#!{sys.executable}\n{GH_STUB}")
        gh.chmod(0o755)
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
        )
        self.git("init", "--quiet", "--bare", "--initial-branch=main", str(self.bare))
        self.git("init", "--quiet", "--initial-branch=main", str(self.wt))
        self.git("-C", str(self.wt), "config", "user.name", "Test")
        self.git("-C", str(self.wt), "config", "user.email", "test@example.invalid")
        self.write("skills/a.md", "a\n")
        self.write("other.nix", "{ }\n")
        self.commit("base")
        self.git("-C", str(self.wt), "remote", "add", "origin", str(self.bare))
        self.git("-C", str(self.wt), "push", "--quiet", "origin", "main")
        self.base = self.head()
        self.git("-C", str(self.wt), "checkout", "--quiet", "-b", BRANCH)
        self.message = self.root / "message.txt"
        self.message.write_text("docs: example change\n\nBody.\n")
        self.body = self.root / "body.md"
        self.body.write_text("Closes #1.\n\n## What\n\nExample.\n")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, path, text):
        target = self.wt / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("-C", str(self.wt), "add", "--all")
        self.git("-C", str(self.wt), "commit", "--quiet", "-m", message)

    def head(self, ref="HEAD"):
        return self.git("-C", str(self.wt), "rev-parse", ref)

    def remote(self):
        process = subprocess.run(
            ["git", "--git-dir", str(self.bare), "rev-parse", f"refs/heads/{BRANCH}"],
            capture_output=True,
            text=True,
        )
        return process.stdout.strip() if process.returncode == 0 else None

    def calls(self, verb):
        if not self.log.exists():
            return []
        lines = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [line for line in lines if line[:2] == verb]

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

    def test_full_run_then_rerun_is_a_no_op(self):
        self.write("skills/a.md", "changed\n")
        self.write("skills/new dir/b.md", "new\n")
        first = self.run_cli()
        self.assertEqual(first["done"], ["commit", "push", "pr"])
        self.assertEqual(first["head"], self.remote())
        self.assertEqual(first["pr"], "https://github.example/pull/1")
        self.assertEqual(first["account"], "ianepreston")
        message = self.git("-C", str(self.wt), "log", "-1", "--format=%B")
        self.assertEqual(message, "docs: example change\n\nBody.")
        self.assertEqual(self.head("HEAD~1"), self.base)
        create = self.calls(["pr", "create"])[0]
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
        self.git("-C", str(self.wt), "push", "--quiet", "origin", BRANCH)
        result = self.run_cli()
        self.assertEqual(result["done"], ["pr"])

    def test_deletions_are_committed(self):
        (self.wt / "skills/a.md").unlink()
        self.run_cli()
        tree = self.git("-C", str(self.wt), "ls-tree", "-r", "--name-only", "HEAD")
        self.assertNotIn("skills/a.md", tree.split())

    def test_path_outside_allow_list_refused_before_any_action(self):
        self.write("skills/a.md", "changed\n")
        self.write("other.nix", "{ x = 1; }\n")
        error = self.run_cli(ok=False)
        self.assertIn("other.nix", error)
        self.assertEqual(self.head(), self.base)
        self.assertIsNone(self.remote())

    def test_committed_path_outside_allow_list_refused(self):
        self.write("other.nix", "{ x = 1; }\n")
        self.commit("child commit")
        self.assertIn("other.nix", self.run_cli(ok=False))
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
        self.git("-C", str(self.wt), "fetch", "--quiet", str(other), "HEAD")
        unrelated = self.head("FETCH_HEAD")
        self.assertIn("does not descend", self.run_cli(ok=False, base=unrelated))
        self.assertIn("not a commit", self.run_cli(ok=False, base="0" * 40))
        self.assertEqual(self.head(), self.base)

    def test_protected_branch_refused(self):
        self.git("-C", str(self.wt), "checkout", "--quiet", "main")
        self.write("skills/a.md", "changed\n")
        self.assertIn("protected", self.run_cli(ok=False, branch="main"))
        self.assertEqual(self.head(), self.base)

    def test_trailers_refused(self):
        self.write("skills/a.md", "changed\n")
        self.message.write_text(
            "docs: x\n\nCo-authored-by: Bot <bot@example.invalid>\n"
        )
        self.assertIn("trailer", self.run_cli(ok=False))
        self.assertEqual(self.head(), self.base)
        self.message.write_text("docs: x\n")
        self.git("-C", str(self.wt), "add", "--all")
        self.git(
            "-C",
            str(self.wt),
            "commit",
            "--quiet",
            "-m",
            "docs: x",
            "-m",
            "co-authored-by: Bot <bot@example.invalid>",
        )
        self.assertIn("trailer", self.run_cli(ok=False))
        self.assertIsNone(self.remote())

    def test_pr_body_trailer_refused(self):
        self.write("skills/a.md", "changed\n")
        self.body.write_text("Body\n\nCo-authored-by: Bot <bot@example.invalid>\n")
        self.assertIn("PR body", self.run_cli(ok=False))
        self.assertEqual(self.calls(["pr", "create"]), [])
        self.assertEqual(self.head(), self.base)

    def test_wrong_gh_account_refused_before_commit(self):
        self.env["STUB_ACTIVE"] = "work-account"
        self.write("skills/a.md", "changed\n")
        error = self.run_cli(ok=False)
        self.assertIn("gh auth switch --hostname github.com --user ianepreston", error)
        self.assertEqual(self.head(), self.base)
        self.assertIsNone(self.remote())

    def test_diverged_remote_is_not_force_pushed(self):
        self.write("skills/a.md", "one\n")
        self.commit("docs: one")
        self.git("-C", str(self.wt), "push", "--quiet", "origin", BRANCH)
        pushed = self.head()
        self.git("-C", str(self.wt), "reset", "--quiet", "--hard", self.base)
        self.write("skills/a.md", "two\n")
        self.assertIn("not an ancestor", self.run_cli(ok=False))
        self.assertEqual(self.remote(), pushed)

    def test_closed_pr_refused(self):
        self.prs.write_text(
            json.dumps([{"number": 9, "url": "u9", "state": "CLOSED", "head": BRANCH}])
        )
        self.write("skills/a.md", "changed\n")
        self.assertIn("closed PR", self.run_cli(ok=False))
        self.assertEqual(self.calls(["pr", "create"]), [])
        self.assertEqual(self.head(), self.base)

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
        self.assertEqual(self.head(), self.base)
        self.assertIsNone(self.remote())


if __name__ == "__main__":
    unittest.main()
