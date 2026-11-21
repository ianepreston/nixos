#!/usr/bin/env python3
"""Mocked identity/failure tests for scripts/activate-nixos.sh (#1018).

Every external command (nix, ssh, sudo, hostname, nix-env, systemd-run, ...) is
a logging stub on PATH. ssh "connects" by running the remote command string
locally, so the real scripts/_activate-nixos/activate.sh executes end to end,
but nothing ever reaches a real host and no real closure is activated.

usage: activate-nixos-test.py REPO_ROOT
"""

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
HELPER = REPO / "scripts" / "activate-nixos.sh"

LOGGER = r"""
log() { printf '%s\t%s\tNIX_SSHOPTS=[%s]\n' "$(basename "$0")" "$*" "${NIX_SSHOPTS-}" >> "$STUB_LOG"; }
"""

STUBS = {
    "nix": r"""
log "$@"
case $1 in
  build | eval)
    case "$*" in *drvPath*) echo "$STUB_DRV" ;; *) echo "$STUB_CLOSURE" ;; esac ;;
  copy) exit "${STUB_COPY_RC:-0}" ;;
esac
""",
    "nix-store": 'log "$@"; echo "$STUB_CLOSURE"',
    "hostname": 'echo "$STUB_HOSTNAME"',
    "sudo": 'log "$@"; exec "$@"',
    "nix-env": 'log "$@"',
    "systemd-run": 'log "$@"; while [ "${1#-}" != "$1" ]; do shift; done; exec "$@"',
    "ssh": r"""
log "$@"
[ -z "${STUB_SSH_RC-}" ] || exit "$STUB_SSH_RC"
# skip options to find the destination, then run the command string locally
while [ $# -gt 0 ]; do
  case $1 in -p | -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift # destination
cat > "$STUB_LOG.stdin" || true
exec bash -c "$*" < "$STUB_LOG.stdin"
""",
}


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, body in STUBS.items():
            p = self.bin / name
            p.write_text("#!/usr/bin/env bash\n" + LOGGER + body)
            p.chmod(0o755)
        self.log = self.tmp / "log"
        self.log.write_text("")
        self.host = "hpp-1"
        self.closure = self.make_closure(self.host)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "STUB_HOSTNAME": self.host,
            "STUB_CLOSURE": str(self.closure),
            "STUB_DRV": str(self.tmp / "store" / "x-nixos-system.drv"),
            "NIX_SSHOPTS": "-o ControlPath=/inherited/socket",
        }

    def make_closure(self, host):
        c = self.tmp / "store" / f"abc123-nixos-system-{host}-25.11"
        (c / "bin").mkdir(parents=True, exist_ok=True)
        s = c / "bin" / "switch-to-configuration"
        s.write_text(
            '#!/usr/bin/env bash\nprintf "ACTIVATED\\t%s\\n" "$*" >> "$STUB_LOG"\n'
        )
        s.chmod(0o755)
        return c

    def run_helper(self, *args, helper=HELPER, **env):
        return subprocess.run(
            ["bash", str(helper), *args],
            env={**self.env, **{k: str(v) for k, v in env.items()}},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=30,
            cwd=self.tmp,
        )

    def lines(self, prefix=None):
        rows = [ln.split("\t") for ln in self.log.read_text().splitlines() if ln]
        return [r for r in rows if prefix is None or r[0] == prefix]

    def activated(self):
        return bool(self.lines("ACTIVATED"))


class RemoteActivation(Harness):
    def test_success_runs_build_copy_activate_in_order(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        order = [row[0] + ":" + row[1].split(" ")[0] for row in self.lines()]
        self.assertEqual(
            [o for o in order if o.split(":")[0] != "hostname"][:3],
            ["nix:build", "nix:copy", "ssh:ipreston@hpp-1"],
        )
        self.assertTrue(self.activated())
        self.assertEqual(self.lines("nix-env")[0][1].split()[-1], str(self.closure))
        # the requested action is what switch-to-configuration receives
        self.assertEqual(self.lines("ACTIVATED")[0][1], "switch")

    def test_inherited_nix_sshopts_is_discarded(self):
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        for row in self.lines("nix") + self.lines("ssh"):
            self.assertNotIn("/inherited/socket", row[2])

    def test_hostname_mismatch_blocks_activation(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_HOSTNAME="amos1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected 'hpp-1'", r.stderr)
        self.assertFalse(self.activated())
        self.assertEqual(self.lines("nix-env"), [])
        self.assertEqual(self.lines("systemd-run"), [])

    def test_closure_name_mismatch_blocks_before_copy(self):
        other = self.make_closure("amos1")
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_CLOSURE=other)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.lines("ssh"), [])
        self.assertEqual([x for x in self.lines("nix") if x[1].startswith("copy")], [])
        self.assertFalse(self.activated())

    def test_target_script_rejects_wrong_closure_on_its_own(self):
        # Defence in depth: even if the local check were bypassed, the script
        # that runs on the target re-asserts the closure name.
        other = self.make_closure("amos1")
        script = REPO / "scripts" / "_activate-nixos" / "activate.sh"
        r = subprocess.run(
            ["bash", str(script), "hpp-1", str(other), "switch"],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.activated())

    def test_identity_checks_share_the_activation_command_chain(self):
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        ssh = self.lines("ssh")
        self.assertEqual(len(ssh), 1, "exactly one connection carries the activation")
        self.assertIn(
            "sudo bash -s -- hpp-1 " + str(self.closure) + " switch", ssh[0][1]
        )
        script = (self.log.parent / "log.stdin").read_text()
        host_check = script.index('"$actual" = "$host"')
        name_check = script.index("*-nixos-system-")
        switch = script.index('switch-to-configuration" "$action"')
        self.assertLess(host_check, switch)
        self.assertLess(name_check, switch)
        # one process: the checks use set -e, so a failure never reaches the switch
        self.assertIn("set -euo pipefail", script)

    def test_connection_failure_is_not_retried(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SSH_RC=255)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.lines("ssh")), 1)
        self.assertFalse(self.activated())

    def test_copy_failure_stops_before_activation(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_COPY_RC=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.lines("ssh"), [])
        self.assertFalse(self.activated())

    def test_check_action_activates_and_copies_nothing(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.activated())
        self.assertEqual([x for x in self.lines("nix") if x[1].startswith("copy")], [])
        self.assertEqual(self.lines("nix-env"), [])
        bad = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "hpp-1",
            "--action",
            "check",
            STUB_HOSTNAME="amos1",
        )
        self.assertNotEqual(bad.returncode, 0)

    def test_boot_and_test_actions(self):
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "test")
        self.assertEqual(self.lines("ACTIVATED")[0][1], "test")
        self.assertEqual(self.lines("nix-env"), [], "test must not record a generation")

    def test_port_and_target_options_scoped_to_target(self):
        self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "10.0.0.5",
            "--port",
            "2222",
            "--target-ssh-opt=-oForwardAgent=yes",
        )
        cp = [x for x in self.lines("nix") if x[1].startswith("copy")][0]
        self.assertIn("-p 2222", cp[2])
        self.assertIn("-oForwardAgent=yes", cp[2])
        self.assertIn("ssh-ng://ipreston@10.0.0.5", cp[1])
        self.assertTrue(
            self.lines("ssh")[0][1].startswith(
                "-p 2222 -oForwardAgent=yes ipreston@10.0.0.5"
            )
        )

    def test_remote_flake_builds_and_activates_on_the_same_target_only(self):
        (self.tmp / "src" / "nixos").mkdir(parents=True)
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "10.0.0.5",
            "--remote-flake",
            "src/nixos",
            "--local-secrets",
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        # the only nix call is the one the stub ssh ran as the "remote" build
        self.assertEqual(
            [x[1].split()[0] for x in self.lines("nix")], ["build"], "nothing copied"
        )
        ssh = self.lines("ssh")
        self.assertEqual(len(ssh), 2)
        self.assertIn("cd src/nixos && nix build", ssh[0][1])
        self.assertIn("--override-input nix-secrets path:../nix-secrets", ssh[0][1])
        self.assertTrue(self.activated())

    def test_remote_flake_still_blocks_wrong_host(self):
        (self.tmp / "src" / "nixos").mkdir(parents=True)
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "10.0.0.5",
            "--remote-flake",
            "src/nixos",
            STUB_HOSTNAME="terra",
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.activated())

    def test_unsafe_values_are_refused(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "evil; reboot")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.lines(), [])


class BuildHost(Harness):
    def run_split(self, **env):
        return self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=/sock/TARGET", "--build-ssh-opt=-oControlPath=/sock/BUILD",
            **env,
        )  # fmt: skip

    def test_build_host_never_sees_target_options_or_activation(self):
        r = self.run_split()
        self.assertEqual(r.returncode, 0, r.stderr)
        for row in self.lines():
            text = "".join(row[1:])
            if "build1" in text:
                self.assertNotIn("TARGET", text)
                self.assertNotIn("switch", text)
                self.assertNotIn("activate", text)
            if "ipreston@hpp-1" in text:
                self.assertNotIn("BUILD", text)
        # no single command touches both hosts (no shared NIX_SSHOPTS / socket)
        for row in self.lines():
            text = "".join(row[1:])
            self.assertFalse(
                "build1" in text and "hpp-1" in text and row[0] != "nix", text
            )
        self.assertTrue(self.activated())

    def test_activation_goes_only_to_the_target(self):
        self.run_split()
        ssh_dests = [r[1] for r in self.lines("ssh")]
        self.assertEqual(
            [d for d in ssh_dests if "switch" in d or "bash -s" in d].__len__(), 1
        )
        self.assertTrue(
            [d for d in ssh_dests if "bash -s" in d][0].endswith("ipreston@hpp-1 sudo bash -s -- hpp-1 "
            + str(self.closure) + " switch")
        )  # fmt: skip

    def test_build_host_closure_name_is_checked_before_target_copy(self):
        other = self.make_closure("amos1")
        r = self.run_split(STUB_CLOSURE=other)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(
            [x for x in self.lines("nix") if "--to ssh-ng://ipreston@" in x[1]], []
        )
        self.assertFalse(self.activated())


class LocalActivation(Harness):
    def test_local_success_goes_through_sudo_and_checks(self):
        r = self.run_helper("--host", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines("ssh"), [])
        self.assertEqual(self.lines("nix")[-1][1].split()[0], "build")
        self.assertTrue(self.activated())

    def test_local_hostname_mismatch_blocks(self):
        r = self.run_helper(
            "--host",
            "luna",
            STUB_HOSTNAME="terra",
            STUB_CLOSURE=self.make_closure("luna"),
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.activated())
        self.assertEqual(self.lines("nix-env"), [])


class LocalSecrets(Harness):
    def make_checkout(self):
        src = self.tmp / "src"
        main = src / "nixos"
        shutil.copytree(
            REPO / "scripts",
            main / "scripts",
            ignore=shutil.ignore_patterns("testdata"),
        )
        (src / "nix-secrets").mkdir()
        git_env = {
            **self.env, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
        }  # fmt: skip

        def git(*a, cwd=main):
            subprocess.run(
                ["git", *a], cwd=cwd, env=git_env, check=True, capture_output=True
            )

        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("commit", "-q", "-m", "init")
        wt = src / "nixos-worktrees" / "wt"
        git("worktree", "add", "-q", str(wt), "-b", "feature")
        return src, main, wt

    def override_of(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        words = self.lines("nix")[0][1].split()
        return words[words.index("nix-secrets") + 1]

    def test_worktree_finds_the_main_checkouts_sibling(self):
        src, _, wt = self.make_checkout()
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--local-secrets",
            "--dry-run",
            helper=wt / "scripts" / "activate-nixos.sh",
        )
        self.assertEqual(self.override_of(r), f"path:{src}/nix-secrets")

    def test_plain_checkout_uses_its_own_sibling(self):
        src, main, _ = self.make_checkout()
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--local-secrets",
            "--dry-run",
            helper=main / "scripts" / "activate-nixos.sh",
        )
        self.assertEqual(self.override_of(r), f"path:{src}/nix-secrets")

    def test_env_override_wins_and_missing_secrets_fail(self):
        _, _, wt = self.make_checkout()
        alt = self.tmp / "alt-secrets"
        alt.mkdir()
        helper = wt / "scripts" / "activate-nixos.sh"
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--local-secrets",
            "--dry-run",
            helper=helper,
            NIX_SECRETS_PATH=alt,
        )
        self.assertEqual(self.override_of(r), f"path:{alt}")
        shutil.rmtree(self.tmp / "src" / "nix-secrets")
        bad = self.run_helper(
            "--host", "hpp-1", "--local-secrets", "--dry-run", helper=helper
        )
        self.assertNotEqual(bad.returncode, 0)

    def test_explicit_override_input_is_passed_through(self):
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--override-input",
            "nix-secrets",
            "path:/abs/secrets",
            "--dry-run",
        )
        self.assertEqual(self.override_of(r), "path:/abs/secrets")


class TaskRouting(unittest.TestCase):
    """The real Task templates render to the helper, never to raw nixos-rebuild."""

    def render(self, *argv):
        task = shutil.which("task")
        if task is None:
            self.skipTest("go-task not available")
        r = subprocess.run(
            [task, "-n", "--silent=false", *argv],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout + r.stderr

    def test_rebuild_tasks(self):
        out = self.render("rebuild")
        self.assertIn("activate-nixos.sh", out)
        self.assertIn("--local-secrets", out)
        out = self.render("rebuild:luna")
        self.assertIn("--host luna", out)

    def test_deploy_preserves_host_and_secrets_override(self):
        out = self.render("deploy:hpp-1")
        self.assertIn("--host hpp-1 --dest hpp-1", out)
        self.assertIn("--local-secrets", out)

    def test_bootstrap_rebuild_keeps_host_and_dest_distinct(self):
        out = self.render(
            "bootstrap:rebuild", "HOST=newbox", "DEST=192.0.2.9", "SSH_PORT=2200"
        )
        self.assertIn('--host "newbox"', out)
        self.assertIn('--dest "192.0.2.9"', out)
        self.assertIn('--port "2200"', out)
        self.assertIn("--remote-flake src/nixos", out)
        off = self.render(
            "bootstrap:rebuild", "HOST=newbox", "DEST=192.0.2.9", "LOCAL_SECRETS=false"
        )
        self.assertNotIn("nix-secrets", off)

    def test_no_task_activates_without_the_helper(self):
        for f in [REPO / "Taskfile.yaml", *sorted((REPO / "taskfiles").glob("*.yaml"))]:
            text = f.read_text()
            for banned in ("nixos-rebuild", "switch-to-configuration"):
                for n, line in enumerate(text.splitlines(), 1):
                    if banned in line and not line.lstrip().startswith(("#", "desc:")):
                        self.fail(f"{f.name}:{n} calls {banned} directly")


if __name__ == "__main__":
    unittest.main(verbosity=2)
