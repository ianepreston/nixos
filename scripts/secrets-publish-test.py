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

ENCRYPTED = """hpp-1:
    app:
        db_password: ENC[AES256_GCM,data:abc,type:str]
sops:
    mac: ENC[AES256_GCM,data:def,type:str]
    version: 3.9.0
"""

# `nix flake update nix-secrets`: lock the url in flake.nix against the bare
# repo in $STUB_REMOTE. STUB_TOUCH_OTHER=1 also edits another lock node, to
# prove the helper notices.
NIX_STUB = r"""
import json, os, re, subprocess, sys
from urllib.parse import parse_qs
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] != ["flake", "update", "nix-secrets"]:
    sys.exit("nix stub: unexpected args %r" % sys.argv[1:])
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
            "sops/hpp-1.yaml", ENCRYPTED.replace("data:abc", f"data:v{n}"), cwd=cwd
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

    def test_explicitly_staged_change_outside_sops_is_published(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.change_secret()
        f.write("README.md", "documented\n")
        f.git("add", "README.md")
        self.ok(f.publish("--message", "m"))
        self.assertEqual(
            f.git("show", "--name-only", "--format=", "HEAD").split(),
            ["README.md", "sops/hpp-1.yaml"],
        )

    def test_plaintext_under_sops_is_refused_and_left_unstaged(self):
        f = self.f
        f.git("switch", "-q", "-c", "feat/x")
        f.write("sops/hpp-1.yaml", "app:\n  db_password: hunter2\n")
        r = self.refused(f.publish("--message", "m"), "without sops metadata")
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
        self.refused(f.publish(), "without sops metadata")
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
        wt = f.root / "elsewhere" / "secrets-wt"
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
