#!/usr/bin/env python3
"""Offline tests for scripts/secrets-publish.sh and scripts/secrets-dir.sh.

The nix-secrets "origin" is a temporary local bare repo, and `nix` is a stub
on PATH that re-locks the nix-secrets input by resolving the flake.nix url's
ref/rev against that bare repo. No network, no real nix-secrets, no sops.

usage: secrets-publish-test.py [REPO_ROOT]
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parent.parent
)
PUBLISH = REPO / "scripts" / "secrets-publish.sh"
BASH = os.path.realpath(shutil.which("bash") or "/bin/bash")
BASE = "git+ssh://git@github.com/ianepreston/nix-secrets.git"
CANONICAL = f"{BASE}?ref=main&shallow=1"

FLAKE_NIX = f"""{{
  inputs = {{
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-secrets = {{
      url = "{CANONICAL}";
      flake = false;
    }};
  }};
  outputs = _: {{ }};
}}
"""


def enc(data, kind="str"):
    return f"ENC[AES256_GCM,data:{data},iv:aXY=,tag:dGFn,type:{kind}]"


ENCRYPTED = f"""hpp-1:
    app:
        db_password: {enc("abc")}
        port: {enc("MTA=", "int")}
#{enc("Y29tbWVudA==", "comment")}
sops:
    age:
        - recipient: age1example
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            YWdl
            -----END AGE ENCRYPTED FILE-----
    mac: {enc("def")}
    version: 3.9.0
"""

# `nix flake update nix-secrets`: lock the url in flake.nix against the bare
# repo in $STUB_REMOTE. Faults, to prove the helper notices and rolls back:
# STUB_FAIL exits 1 without writing; STUB_TOUCH_OTHER edits another lock node;
# STUB_DROP_REF drops locked.ref; STUB_STALE_ORIGINAL leaves original.ref at
# main and drops original.rev. Any other nix command is logged as JSON and
# succeeds (for the matrix task).
NIX_STUB = r"""
import json, os, re, subprocess, sys
from urllib.parse import parse_qs
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] != ["flake", "update", "nix-secrets"]:
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
    sys.exit(0)
if os.environ.get("STUB_FAIL"):
    sys.exit("nix stub: simulated fetch failure")
url = re.search(r'url = "(git\+ssh://[^"]*nix-secrets\.git[^"]*)";', open("flake.nix").read()).group(1)
q = {k: v[0] for k, v in parse_qs(url.partition("?")[2]).items()}
git = ["git", "--git-dir", os.environ["STUB_REMOTE"]]
rev = q.get("rev") or subprocess.run(
    git + ["rev-parse", "refs/heads/" + q["ref"]], check=True, capture_output=True, text=True
).stdout.strip()
subprocess.run(git + ["cat-file", "-e", rev + "^{commit}"], check=True)
lock = json.load(open("flake.lock"))
node = lock["nodes"][lock["root"]]
node = lock["nodes"][node["inputs"]["nix-secrets"]]
node["locked"] = {"lastModified": 1, "narHash": "sha256-stub", "ref": q["ref"], "rev": rev,
                  "shallow": True, "type": "git", "url": url.partition("?")[0][4:]}
node["original"] = {"ref": q["ref"], "type": "git", "url": url.partition("?")[0][4:]}
if "rev" in q:
    node["original"]["rev"] = q["rev"]
if os.environ.get("STUB_TOUCH_OTHER"):
    lock["nodes"]["nixpkgs"]["locked"]["rev"] = "0" * 40
if os.environ.get("STUB_DROP_REF"):
    del node["locked"]["ref"]
if os.environ.get("STUB_STALE_ORIGINAL"):
    node["original"]["ref"] = "stale"
    node["original"].pop("rev", None)
json.dump(lock, open("flake.lock", "w"), indent=2)
"""


class Fixture:
    """A bare nix-secrets origin with one encrypted main commit, a primary
    clone of it, a NixOS checkout whose lock pins main, and a stub nix."""

    def __init__(self, root):
        self.root = Path(root)
        home = self.root / "home"
        home.mkdir()
        self.env = {
            k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "STUB_"))
        }
        self.env.update(
            HOME=str(home),
            XDG_CONFIG_HOME=str(home / "xdg"),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_TERMINAL_PROMPT="0",
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@example.invalid",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@example.invalid",
            GIT_CONFIG_COUNT="3",
            GIT_CONFIG_KEY_0="core.hooksPath",
            GIT_CONFIG_VALUE_0="/dev/null",
            GIT_CONFIG_KEY_1="commit.gpgsign",
            GIT_CONFIG_VALUE_1="false",
            GIT_CONFIG_KEY_2="init.defaultBranch",
            GIT_CONFIG_VALUE_2="main",
        )
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        nix = bin_dir / "nix"
        nix.write_text(f"#!{sys.executable}\n{NIX_STUB}")
        nix.chmod(0o755)
        self.log = self.root / "nix.log"
        self.log.touch()
        self.remote = self.root / "remote.git"
        self.env.update(
            PATH=f"{bin_dir}{os.pathsep}{self.env['PATH']}",
            STUB_LOG=str(self.log),
            STUB_REMOTE=str(self.remote),
        )

        self.git("init", "--bare", "-q", str(self.remote), cwd=self.root)
        self.secrets = self.root / "nix-secrets"
        self.git("clone", "-q", str(self.remote), str(self.secrets), cwd=self.root)
        self.write("sops/hpp-1.yaml", ENCRYPTED)
        self.write(".sops.yaml", "creation_rules: []\n")
        self.write("README.md", "secrets\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")
        self.git("push", "-q", "origin", "HEAD:refs/heads/main")
        self.git("branch", "-q", "--set-upstream-to=origin/main")
        self.main0 = self.rev("HEAD")

        self.nixos = self.root / "nixos"
        self.nixos.mkdir()
        (self.nixos / "flake.nix").write_text(FLAKE_NIX)
        lock = {
            "nodes": {
                "nix-secrets": {
                    "locked": {"ref": "main", "rev": self.main0, "type": "git"},
                    "original": {"ref": "main", "type": "git"},
                },
                "nixpkgs": {"locked": {"rev": "1" * 40, "type": "github"}},
                "root": {
                    "inputs": {"nix-secrets": "nix-secrets", "nixpkgs": "nixpkgs"}
                },
            },
            "root": "root",
            "version": 7,
        }
        (self.nixos / "flake.lock").write_text(json.dumps(lock, indent=2))
        self.git("init", "-q", cwd=self.nixos)
        self.git("add", "-A", cwd=self.nixos)
        self.git("commit", "-qm", "nixos", cwd=self.nixos)

    def git(self, *args, cwd=None):
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.secrets,
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def rev(self, ref, cwd=None):
        return self.git("rev-parse", ref, cwd=cwd)

    def remote_ref(self, name):
        r = subprocess.run(
            ["git", "--git-dir", str(self.remote), "rev-parse", "--verify", "-q", name],
            env=self.env,
            capture_output=True,
            text=True,
        )
        return r.stdout.strip() or None

    def write(self, rel, text, cwd=None):
        p = Path(cwd or self.secrets) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def change_secret(self, cwd=None, n=1):
        self.write(
            "sops/hpp-1.yaml", ENCRYPTED.replace("data:abc,", f"data:v{n},"), cwd=cwd
        )

    def publish(self, *args, secrets_dir=None, extra_env=None):
        return self.run(
            "publish",
            "--secrets-dir",
            str(secrets_dir or self.secrets),
            *args,
            extra_env=extra_env,
        )

    def run(self, *args, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        return subprocess.run(
            [BASH, str(PUBLISH), *args, "--nixos-dir", str(self.nixos)],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
        )

    def flake_url(self):
        for line in (self.nixos / "flake.nix").read_text().splitlines():
            if "nix-secrets.git" in line:
                return line.split('"')[1]
        raise AssertionError("no nix-secrets url")

    def lock(self):
        return json.loads((self.nixos / "flake.lock").read_text())

    def locked(self):
        return self.lock()["nodes"]["nix-secrets"]["locked"]


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def ok(self, r):
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def refused(self, r, needle):
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(needle, r.stderr)
        return r

    def assert_untouched(self):
        """Nothing pinned, nothing locked, nix not run, main not moved."""
        self.assertEqual(self.f.flake_url(), CANONICAL)
        self.assertEqual(self.f.locked()["rev"], self.f.main0)
        self.assertEqual(self.f.log.read_text(), "")
        self.assertEqual(self.f.remote_ref("refs/heads/main"), self.f.main0)

    def test_new_branch_tracking_main_first_push_pins_exact_commit(self):
        # `git switch -c x origin/main` sets upstream origin/main: the old
        # task's plain `git push` would have targeted main.
        f = self.f
        f.git("switch", "-q", "-c", "feat/app", "origin/main")
        f.change_secret()
        r = self.ok(f.publish("--message", "add app secret"))
        head = f.rev("HEAD")
        self.assertNotEqual(head, f.main0)
        self.assertEqual(f.remote_ref("refs/heads/feat/app"), head)
        self.assertEqual(f.remote_ref("refs/heads/main"), f.main0)
        self.assertEqual(f.git("rev-parse", "--abbrev-ref", "@{u}"), "origin/feat/app")
        self.assertEqual(f.flake_url(), f"{BASE}?ref=feat/app&rev={head}&shallow=1")
        self.assertEqual(f.locked()["rev"], head)
        self.assertEqual(f.locked()["ref"], "feat/app")
        self.assertIn(f"pinned nix-secrets to feat/app at {head}", r.stdout)
        self.assertIn(f"task secrets:pin-main EXPECT={head}", r.stdout)
        self.assertEqual(f.log.read_text(), "flake update nix-secrets\n")
        # Unrelated lock entries are byte-for-byte the same.
        self.assertEqual(f.lock()["nodes"]["nixpkgs"]["locked"]["rev"], "1" * 40)

    def test_branch_without_upstream_is_pushed_and_tracked(self):
        f = self.f
        f.git("switch", "-q", "--no-track", "-c", "feat/new", "main")
        f.change_secret()
        f.git("commit", "-qam", "manual commit")
        head = f.rev("HEAD")
        self.ok(f.publish())  # clean tree: no MSG needed
        self.assertEqual(f.remote_ref("refs/heads/feat/new"), head)
        self.assertEqual(f.git("rev-parse", "--abbrev-ref", "@{u}"), "origin/feat/new")
        self.assertEqual(f.locked()["rev"], head)

    def test_linked_worktree_publishes_only_its_own_branch(self):
        f = self.f
        # The primary checkout has an unrelated, uncommitted edit.
        f.change_secret(n=99)
        wt = f.root / "nix-secrets-wt"
        f.git("worktree", "add", "-q", "-b", "feat/wt", str(wt), "origin/main")
        f.change_secret(cwd=wt, n=2)
        r = self.ok(f.publish("--message", "wt change", secrets_dir=wt))
        head = f.rev("HEAD", cwd=wt)
        self.assertIn(f"nix-secrets checkout: {wt.resolve()}", r.stdout)
        self.assertEqual(f.remote_ref("refs/heads/feat/wt"), head)
        pushed = f.git("show", f"{head}:sops/hpp-1.yaml")
        self.assertIn("data:v2", pushed)
        self.assertNotIn("data:v99", pushed)
        # The primary checkout's edit is still just an edit there.
        self.assertIn("sops/hpp-1.yaml", f.git("status", "--porcelain"))
        self.assertEqual(f.rev("main"), f.main0)
        self.assertEqual(f.locked()["rev"], head)

    def test_dirty_tree_without_message_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.refused(f.publish(), "re-run with MSG")
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))
        self.assert_untouched()

    def test_staged_change_without_message_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        f.git("add", "sops/hpp-1.yaml")
        self.refused(f.publish(), "re-run with MSG")
        self.assert_untouched()

    def test_untracked_files_are_refused_even_with_message(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        f.write("notes.txt", "db_password: hunter2\n")
        r = self.refused(f.publish("--message", "m"), "untracked files")
        self.assertIn("notes.txt", r.stderr)
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))
        self.assert_untouched()

    def test_unstaged_change_outside_sops_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        f.write("README.md", "unrelated edit\n")
        r = self.refused(f.publish("--message", "m"), "outside sops/")
        self.assertIn("README.md", r.stderr)
        self.assertEqual(f.rev("HEAD"), f.main0)
        self.assert_untouched()

    def test_explicitly_staged_change_outside_sops_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        f.write("README.md", "documented\n")
        f.git("add", "README.md")
        r = self.refused(f.publish("--message", "m"), "outside sops/")
        self.assertIn("README.md", r.stderr)
        self.assertEqual(f.rev("HEAD"), f.main0)
        self.assert_untouched()

    def test_plaintext_under_sops_is_refused_and_left_unstaged(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/hpp-1.yaml", "app:\n  db_password: hunter2\n")
        r = self.refused(f.publish("--message", "m"), "plaintext guard failed")
        self.assertIn("sops/hpp-1.yaml", r.stderr)
        self.assertEqual(f.git("diff", "--cached", "--name-only"), "")
        self.assertEqual(f.rev("HEAD"), f.main0)
        self.assert_untouched()

    def test_plaintext_in_an_existing_commit_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/new.yaml", "token: hunter2\n")
        f.git("add", "sops/new.yaml")
        f.git("commit", "-qm", "oops")
        self.refused(f.publish(), "plaintext guard failed")
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))
        self.assert_untouched()

    def test_branch_not_containing_the_locked_revision_is_refused(self):
        f = self.f
        # main moves on and the NixOS lock follows it...
        f.change_secret(n=5)
        f.git("commit", "-qam", "newer main")
        f.git("push", "-q", "origin", "main")
        self.ok(f.run("restore-main"))
        newer = f.rev("main")
        self.assertEqual(f.locked()["rev"], newer)
        f.log.write_text("")
        # ...but a branch cut from the stale commit would drop that change.
        f.git("switch", "-q", "-c", "feat/stale", f.main0)
        f.change_secret(n=6)
        self.refused(f.publish("--message", "m"), "does not contain the locked")
        self.assertIsNone(f.remote_ref("refs/heads/feat/stale"))
        self.assertEqual(f.locked()["rev"], newer)
        self.assertEqual(f.log.read_text(), "")

    def test_diverged_remote_branch_is_not_force_pushed(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret(n=1)
        self.ok(f.publish("--message", "one"))
        first = f.rev("HEAD")
        f.log.write_text("")
        f.change_secret(n=2)
        f.git("commit", "-q", "--amend", "-am", "rewritten")
        self.refused(f.publish(), "does not contain the locked")
        self.assertEqual(f.remote_ref("refs/heads/feat/x"), first)
        self.assertEqual(f.locked()["rev"], first)
        self.assertEqual(f.log.read_text(), "")

    def test_detached_head_is_refused(self):
        f = self.f
        f.git("switch", "-q", "--detach", "HEAD")
        self.refused(f.publish(), "detached HEAD")
        self.assert_untouched()

    def test_branch_name_unsafe_for_a_url_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat&rev=x")
        self.refused(f.publish(), "must match")
        self.assert_untouched()

    def test_missing_checkout_is_refused(self):
        self.refused(
            self.f.publish(secrets_dir=self.f.root / "absent"), "checkout not found"
        )
        self.assert_untouched()

    def test_lock_changes_outside_nix_secrets_fail(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.refused(
            f.publish("--message", "m", extra_env={"STUB_TOUCH_OTHER": "1"}),
            "changed outside the nix-secrets node",
        )

    def test_publish_on_main_pins_the_canonical_input(self):
        f = self.f
        f.change_secret(n=3)
        r = self.ok(f.publish("--message", "main change"))
        head = f.rev("HEAD")
        self.assertEqual(f.remote_ref("refs/heads/main"), head)
        self.assertEqual(f.flake_url(), CANONICAL)
        self.assertEqual(f.locked()["rev"], head)
        self.assertNotIn("Temporary pin", r.stdout)

    def test_publish_on_clean_main_is_a_relock(self):
        f = self.f
        self.ok(f.publish())
        self.assertEqual(f.flake_url(), CANONICAL)
        self.assertEqual(f.locked()["rev"], f.main0)
        self.assertEqual(f.remote_ref("refs/heads/main"), f.main0)

    def test_restore_main_after_merge_checks_the_pin_contains_the_branch(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.ok(f.publish("--message", "m"))
        branch_head = f.rev("HEAD")
        # Not merged yet: main does not contain the branch commit.
        self.refused(
            f.run(
                "restore-main", "--secrets-dir", str(f.secrets), "--expect", branch_head
            ),
            "does not contain",
        )
        # Merge into main (as the nix-secrets PR would), then restore.
        f.git("switch", "-q", "main")
        f.git("merge", "-q", "--no-ff", "-m", "merge", "feat/x")
        f.git("push", "-q", "origin", "main")
        merged = f.rev("main")
        r = self.ok(
            f.run(
                "restore-main", "--secrets-dir", str(f.secrets), "--expect", branch_head
            )
        )
        self.assertEqual(f.flake_url(), CANONICAL)
        self.assertEqual(f.locked()["rev"], merged)
        self.assertIn(f"pinned nix-secrets to main at {merged}", r.stdout)
        self.assertEqual(f.lock()["nodes"]["nixpkgs"]["locked"]["rev"], "1" * 40)
        # The temporary ref can now go; the final pin does not need it.
        f.git("push", "-q", "origin", ":refs/heads/feat/x")
        self.assertEqual(f.locked()["rev"], merged)

    def flake_files(self):
        return (
            (self.f.nixos / "flake.nix").read_bytes(),
            (self.f.nixos / "flake.lock").read_bytes(),
        )

    def index_state(self, cwd=None):
        """Index entries plus worktree diff: what a refusal must not change."""
        f = self.f
        return (
            f.git("ls-files", "-s", cwd=cwd),
            f.git("diff", "--cached", cwd=cwd),
            f.git("diff", cwd=cwd),
        )

    # --- finding 1: flake.nix / flake.lock changes are transactional -------

    def test_failed_nix_update_restores_flake_files(self):
        f = self.f
        before = self.flake_files()
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        r = self.refused(
            f.publish("--message", "m", extra_env={"STUB_FAIL": "1"}),
            "nix flake update nix-secrets failed",
        )
        self.assertIn("restored flake.nix and flake.lock", r.stderr)
        self.assertEqual(self.flake_files(), before)

    def test_failed_lock_checks_restore_flake_files(self):
        for fault in ("STUB_TOUCH_OTHER", "STUB_DROP_REF", "STUB_STALE_ORIGINAL"):
            with self.subTest(fault=fault):
                self.tmp.cleanup()
                self.setUp()
                f = self.f
                before = self.flake_files()
                f.git("switch", "-q", "-c", "feat/x")
                f.change_secret()
                r = f.publish("--message", "m", extra_env={fault: "1"})
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.flake_files(), before)

    def test_pin_main_expect_before_merge_keeps_the_branch_pin(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.ok(f.publish("--message", "m"))
        head = f.rev("HEAD")
        pinned = self.flake_files()
        f.log.write_text("")
        self.refused(
            f.run("restore-main", "--secrets-dir", str(f.secrets), "--expect", head),
            "does not contain",
        )
        self.assertEqual(self.flake_files(), pinned)
        self.assertEqual(f.log.read_text(), "")  # refused before any nix run

    def test_pin_main_failure_restores_the_branch_pin(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.ok(f.publish("--message", "m"))
        pinned = self.flake_files()
        for fault in ("STUB_FAIL", "STUB_STALE_ORIGINAL"):
            with self.subTest(fault=fault):
                self.assertNotEqual(
                    f.run("restore-main", extra_env={fault: "1"}).returncode, 0
                )
                self.assertEqual(self.flake_files(), pinned)

    # --- finding 2: plaintext guard covers every pushed commit -------------

    def test_plaintext_in_an_intermediate_commit_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/new.yaml", "token: hunter2\n")
        f.git("add", "sops/new.yaml")
        f.git("commit", "-qm", "plaintext")
        f.write("sops/new.yaml", ENCRYPTED)
        f.git("commit", "-qam", "encrypt it")
        r = self.refused(f.publish(), "plaintext guard failed")
        self.assertIn("sops/new.yaml", r.stderr)
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))
        self.assert_untouched()

    def test_plaintext_deleted_in_a_later_commit_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/leak.yaml", "token: hunter2\n")
        f.git("add", "sops/leak.yaml")
        f.git("commit", "-qm", "oops")
        f.git("rm", "-q", "sops/leak.yaml")
        f.git("commit", "-qm", "remove it")
        self.refused(f.publish(), "plaintext guard failed")
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))

    def test_plaintext_value_beside_sops_metadata_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write(
            "sops/hpp-1.yaml",
            ENCRYPTED.replace("hpp-1:\n", "hpp-1:\n    leaked: hunter2\n"),
        )
        r = self.refused(f.publish("--message", "m"), "plaintext guard failed")
        self.assertIn("not an ENC[...] envelope", r.stderr)
        self.assert_untouched()

    def test_non_string_plaintext_values_are_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        for leaf in ("port: 5432", "flag: false", "empty: null", "_unencrypted: x"):
            with self.subTest(leaf=leaf):
                f.write(
                    "sops/hpp-1.yaml",
                    ENCRYPTED.replace("hpp-1:\n", f"hpp-1:\n    {leaf}\n"),
                )
                self.refused(f.publish("--message", "m"), "plaintext guard failed")
        self.assert_untouched()

    def test_plaintext_comment_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/hpp-1.yaml", "# password is hunter2\n" + ENCRYPTED)
        r = self.refused(f.publish("--message", "m"), "plaintext comment")
        self.assertIn("sops/hpp-1.yaml", r.stderr)
        self.assert_untouched()

    def test_sops_metadata_without_encrypted_mac_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/hpp-1.yaml", f"a: {enc('x')}\nsops:\n    version: 3.9.0\n")
        self.refused(f.publish("--message", "m"), "plaintext guard failed")

    def test_json_sops_documents_are_checked(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        good = {"a": {"b": [enc("eA==")]}, "sops": {"mac": enc("bQ=="), "version": "3"}}
        f.write("sops/x.json", json.dumps(good))
        f.git("add", "sops/x.json")
        self.ok(f.publish("--message", "json"))
        f.log.write_text("")
        good["a"]["c"] = "hunter2"
        f.write("sops/x.json", json.dumps(good))
        self.refused(f.publish("--message", "leak"), "plaintext guard failed")

    def test_other_formats_under_sops_are_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/key.txt", "secret\n")
        f.git("add", "sops/key.txt")
        self.refused(f.publish("--message", "m"), "not a .yaml/.json sops file")

    def test_committed_change_outside_sops_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("README.md", "edit\n")
        f.git("commit", "-qam", "docs")
        r = self.refused(f.publish(), "outside sops/")
        self.assertIn("README.md", r.stderr)
        self.assertIsNone(f.remote_ref("refs/heads/feat/x"))

    def test_commits_already_on_the_remote_are_not_rechecked(self):
        # A README change already pushed to main (by hand) does not block a
        # later secrets publish from a branch on top of it.
        f = self.f
        f.write("README.md", "edit\n")
        f.git("commit", "-qam", "docs")
        f.git("push", "-q", "origin", "main")
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.ok(f.publish("--message", "m"))

    # --- finding 3: the index is never mutated destructively ---------------

    def test_path_with_staged_and_unstaged_changes_is_refused(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret(n=1)
        f.git("add", "sops/hpp-1.yaml")
        f.change_secret(n=2)
        before = self.index_state()
        r = self.refused(f.publish("--message", "m"), "both staged and unstaged")
        self.assertIn("sops/hpp-1.yaml", r.stderr)
        self.assertEqual(self.index_state(), before)
        self.assert_untouched()

    def test_guard_failure_restores_the_exact_index(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        # An index-only intermediate version of one file...
        f.change_secret(n=1)
        f.git("add", "sops/hpp-1.yaml")
        # ...and an unstaged plaintext file the guard will reject.
        f.write("sops/other.yaml", ENCRYPTED)
        f.git("add", "sops/other.yaml")
        f.git("commit", "-qm", "base")
        f.write("sops/other.yaml", "token: hunter2\n")
        f.change_secret(n=1)  # worktree == index for hpp-1.yaml
        before = self.index_state()
        self.refused(f.publish("--message", "m"), "plaintext guard failed")
        self.assertEqual(self.index_state(), before)
        self.assertIn("data:v1,", f.git("show", ":sops/hpp-1.yaml"))

    # --- finding 4: the full branch ref, never an ambiguous short name -----

    def test_branch_with_a_same_named_tag_pushes_the_branch(self):
        f = self.f
        f.git("tag", "feat/app")
        f.git("switch", "-q", "-c", "feat/app")
        self.assertEqual(f.git("rev-parse", "--abbrev-ref", "HEAD"), "heads/feat/app")
        f.change_secret()
        self.ok(f.publish("--message", "m"))
        head = f.rev("HEAD")
        self.assertEqual(f.remote_ref("refs/heads/feat/app"), head)
        self.assertIsNone(f.remote_ref("refs/heads/heads/feat/app"))
        self.assertEqual(f.flake_url(), f"{BASE}?ref=feat/app&rev={head}&shallow=1")

    # --- finding 6: locked and original must both match flake.nix ----------

    def test_branch_pin_records_matching_locked_and_original(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.ok(f.publish("--message", "m"))
        head = f.rev("HEAD")
        node = f.lock()["nodes"]["nix-secrets"]
        self.assertEqual(
            (node["locked"]["ref"], node["locked"]["rev"]), ("feat/x", head)
        )
        self.assertEqual(
            (node["original"]["ref"], node["original"]["rev"]), ("feat/x", head)
        )

    def test_missing_locked_ref_fails_a_branch_pin(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        self.refused(
            f.publish("--message", "m", extra_env={"STUB_DROP_REF": "1"}),
            "does not match ref=feat/x",
        )
        self.assertEqual(f.flake_url(), CANONICAL)

    def test_pin_main_without_expect_checks_lock_consistency(self):
        f = self.f
        r = self.refused(
            f.run("restore-main", extra_env={"STUB_STALE_ORIGINAL": "1"}),
            "does not match ref=main",
        )
        self.assertIn("restored", r.stderr)
        self.assertEqual(f.locked()["rev"], f.main0)

    def test_task_wiring_passes_an_explicit_checkout(self):
        f = self.f
        (f.nixos / "scripts").mkdir()
        (f.nixos / "taskfiles").mkdir()
        for name in ("secrets-publish.sh", "secrets-dir.sh"):
            shutil.copy(REPO / "scripts" / name, f.nixos / "scripts" / name)
        shutil.copy(REPO / "taskfiles" / "secrets.yaml", f.nixos / "taskfiles")
        (f.nixos / "Taskfile.yaml").write_text(
            "version: '3'\nincludes:\n  secrets: ./taskfiles/secrets.yaml\n"
        )
        wt = f.root / "elsewhere" / 'wt $HOME "q" x'
        f.git("worktree", "add", "-q", "-b", "feat/task", str(wt), "origin/main")
        f.change_secret(cwd=wt, n=7)
        r = subprocess.run(
            ["task", "secrets:publish", f"SECRETS_DIR={wt}", "MSG=it's a test"],
            cwd=f.nixos,
            env=f.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        head = f.rev("HEAD", cwd=wt)
        self.assertEqual(f.git("log", "-1", "--format=%s", cwd=wt), "it's a test")
        self.assertEqual(f.remote_ref("refs/heads/feat/task"), head)
        self.assertEqual(f.locked()["rev"], head)


LOG_STUB = r"""
import json, os, sys
name = os.path.basename(sys.argv[0])
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps([name, os.getcwd(), sys.argv[1:]]) + "\n")
if name == "sops" and sys.argv[1:2] == ["-d"]:
    print("{}")
if name == "openssl":
    print("ab" * int(sys.argv[-1]))
"""


class TaskQuotingTest(unittest.TestCase):
    """Every user value in taskfiles/secrets.yaml reaches the shell quoted: a
    checkout path with `$`, a space and a quote is used verbatim, and names
    that could break the sops/yq paths are refused."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name).resolve()
        self.nixos = root / "nixos"
        (self.nixos / "scripts" / "_sops-matrix").mkdir(parents=True)
        (self.nixos / "taskfiles").mkdir()
        for name in ("secrets-publish.sh", "secrets-dir.sh"):
            shutil.copy(REPO / "scripts" / name, self.nixos / "scripts" / name)
        (self.nixos / "scripts" / "_sops-matrix" / "consumers.nix").write_text(
            "_: { }\n"
        )
        shutil.copy(REPO / "taskfiles" / "secrets.yaml", self.nixos / "taskfiles")
        (self.nixos / "Taskfile.yaml").write_text(
            "version: '3'\nincludes:\n  secrets: ./taskfiles/secrets.yaml\n"
        )
        self.secrets = root / 'nix-secrets $HOME "q" x'
        (self.secrets / "sops").mkdir(parents=True)
        (self.secrets / "sops" / "hpp-1.yaml").write_text(ENCRYPTED)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("sops", "openssl", "nix"):
            stub = bin_dir / name
            stub.write_text(f"#!{sys.executable}\n{LOG_STUB}")
            stub.chmod(0o755)
        self.log = root / "log"
        self.log.touch()
        self.env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("SECRETS_DIR", "NIX_SECRETS_PATH")
        }
        self.env.update(
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            STUB_LOG=str(self.log),
            HOME=str(root),
        )

    def tearDown(self):
        self.tmp.cleanup()

    def task(self, *argv, env=None):
        return subprocess.run(
            ["task", *argv],
            cwd=self.nixos,
            env=dict(self.env, **(env or {})),
            capture_output=True,
            text=True,
        )

    def calls(self, name):
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [(cwd, args) for n, cwd, args in rows if n == name]

    def test_checkout_path_with_shell_metacharacters_is_used_verbatim(self):
        cases = {
            "secrets:edit:hpp-1": ["sops/hpp-1.yaml"],
            "secrets:view:hpp-1": ["-d", "sops/hpp-1.yaml"],
            "secrets:rekey": ["updatekeys", "--yes", "sops/hpp-1.yaml"],
        }
        for argv, want in cases.items():
            for via_env in (False, True):
                with self.subTest(task=argv, via_env=via_env):
                    self.log.write_text("")
                    if via_env:
                        r = self.task(argv, env={"SECRETS_DIR": str(self.secrets)})
                    else:
                        r = self.task(argv, f"SECRETS_DIR={self.secrets}")
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertEqual(self.calls("sops"), [(str(self.secrets), want)])

    def test_generators_use_the_quoted_checkout_and_names(self):
        cases = [
            (("secrets:dbpw", "APP=foo"), ['["foo"]["db_password"]']),
            (
                ("secrets:oidc", "APP=foo"),
                ['["foo"]["oidc_client_id"]', '["foo"]["oidc_client_secret"]'],
            ),
            (("secrets:secret", "APP=foo", "KEY=bar", "LEN=4"), ['["foo"]["bar"]']),
        ]
        for argv, paths in cases:
            with self.subTest(task=argv[0]):
                self.log.write_text("")
                r = self.task(*argv, f"SECRETS_DIR={self.secrets}")
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                sets = [a for cwd, a in self.calls("sops") if a[0] == "set"]
                self.assertEqual([a[2] for a in sets], paths)
                self.assertTrue(all(a[1] == "sops/hpp-1.yaml" for a in sets))
                self.assertTrue(
                    all(cwd == str(self.secrets) for cwd, _ in self.calls("sops"))
                )

    def test_unsafe_names_are_refused_before_sops_runs(self):
        for argv in (
            ("secrets:dbpw", 'APP=x"]["y'),
            ("secrets:dbpw", "APP=x; touch pwned"),
            ("secrets:secret", "APP=a", "KEY=$(touch pwned)"),
            ("secrets:secret", "APP=a", "KEY=b", "LEN=4; touch pwned"),
            ("secrets:oidc", "APP=a", "HOST=../x"),
            ("secrets:dbpw", "APP=a", "FORCE=yes"),
        ):
            with self.subTest(argv=argv):
                self.log.write_text("")
                r = self.task(*argv, f"SECRETS_DIR={self.secrets}")
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.calls("sops"), [])
                self.assertFalse((self.nixos / "pwned").exists())
                self.assertFalse((self.secrets / "pwned").exists())

    def test_matrix_passes_the_quoted_checkout_to_nix(self):
        r = self.task("secrets:matrix", "OFFLINE=true", f"SECRETS_DIR={self.secrets}")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        argvs = [a for _, a in self.calls("nix")]
        self.assertIn(f"path:{self.secrets}", argvs[0])
        i = argvs[1].index("--secrets-dir")
        self.assertEqual(argvs[1][i + 1], str(self.secrets))


class SecretsDirTest(unittest.TestCase):
    """scripts/secrets-dir.sh: explicit checkout first, then siblings."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("SECRETS_DIR", "NIX_SECRETS_PATH") and not k.startswith("GIT_")
        }
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@example.invalid",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@example.invalid",
        )
        self.primary = self.root / "src" / "nixos"
        self.primary.mkdir(parents=True)
        g = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]
        subprocess.run([*g, "init", "-q"], cwd=self.primary, env=self.env, check=True)
        subprocess.run(
            [*g, "commit", "-q", "--allow-empty", "-m", "x"],
            cwd=self.primary,
            env=self.env,
            check=True,
        )
        self.wt = self.root / "wts" / "feat"
        subprocess.run(
            [*g, "worktree", "add", "-q", str(self.wt)],
            cwd=self.primary,
            env=self.env,
            check=True,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def resolve(self, cwd, **env):
        return subprocess.run(
            [BASH, str(REPO / "scripts" / "secrets-dir.sh")],
            cwd=cwd,
            env=dict(self.env, **env),
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def test_linked_worktree_falls_back_to_the_primary_sibling(self):
        (self.root / "src" / "nix-secrets").mkdir()
        self.assertEqual(self.resolve(self.wt), str(self.root / "src" / "nix-secrets"))

    def test_own_sibling_wins_over_the_primary_sibling(self):
        (self.root / "src" / "nix-secrets").mkdir()
        (self.root / "wts" / "nix-secrets").mkdir()
        self.assertEqual(self.resolve(self.wt), str(self.root / "wts" / "nix-secrets"))

    def test_explicit_checkout_wins(self):
        (self.root / "src" / "nix-secrets").mkdir()
        other = self.root / "other"
        other.mkdir()
        self.assertEqual(self.resolve(self.wt, SECRETS_DIR=str(other)), str(other))
        self.assertEqual(self.resolve(self.wt, NIX_SECRETS_PATH=str(other)), str(other))

    def test_nothing_found_prints_the_sibling_path_without_failing(self):
        self.assertEqual(self.resolve(self.wt), f"{self.wt}/../nix-secrets")


if __name__ == "__main__":
    unittest.main(verbosity=2)
