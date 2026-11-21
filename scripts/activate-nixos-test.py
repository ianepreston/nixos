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
STORE_LINE = "store_dir=/nix/store\n"
HASH = "abcdfghijklmnpqrsvwxyz0123456789"  # 32 nix-base32 chars
VERSION = "26.05.20261115.b349185"

LOGGER = r"""
log() { printf '%s\t%s\tNIX_SSHOPTS=[%s]\n' "$(basename "$0")" "$*" "${NIX_SSHOPTS-}" >> "$STUB_LOG"; }
"""

STUBS = {
    "nix": r"""
log "$@"
case $1 in
  build | eval)
    case "$*" in
      *drvPath*) echo "$STUB_DRV" ;;
      *networking.hostName*) echo "$STUB_CFG_HOSTNAME" ;;
      *) echo "$STUB_CLOSURE" ;;
    esac ;;
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
case " $* " in
  *" -G "*) # effective config: an explicit ControlPath wins, else "ssh_config"
    cp=${STUB_SSH_CONTROLPATH-}
    for a in "$@"; do case $a in -oControlPath=*) cp=${a#-oControlPath=} ;; esac; done
    [ -z "$cp" ] || printf 'controlpath %s\n' "$cp"
    printf 'controlmaster auto\n'
    exit 0 ;;
esac
[ -z "${STUB_SSH_RC-}" ] || exit "$STUB_SSH_RC"
# skip options to find the destination, then run the command string locally
while [ $# -gt 0 ]; do
  case $1 in -p | -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift # destination
if [ -n "${STUB_SSH_NULL_STDIN-}" ]; then # what `ssh -n` does
  exec bash -c "$*" < /dev/null
fi
cat > "$STUB_LOG.stdin" || true
exec bash -c "$*" < "$STUB_LOG.stdin"
""",
}


def make_repo(dest, store):
    """A copy of the repo's scripts and Taskfiles with the store dir pointed at
    a temp directory: the only edit, asserted to hit exactly one line each."""
    repo = dest / "repo"
    shutil.copytree(REPO / "scripts", repo / "scripts")
    shutil.copytree(REPO / "taskfiles", repo / "taskfiles")
    shutil.copy(REPO / "Taskfile.yaml", repo / "Taskfile.yaml")
    for rel in ("scripts/activate-nixos.sh", "scripts/_activate-nixos/activate.sh"):
        f = repo / rel
        text = f.read_text()
        assert text.count(STORE_LINE) == 1, f"{rel}: expected one {STORE_LINE!r}"
        f.write_text(text.replace(STORE_LINE, f"store_dir={store}\n"))
    (dest / "nix-secrets").mkdir()
    return repo


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.store = self.tmp / "store"
        self.store.mkdir()
        self.repo = make_repo(self.tmp, self.store)
        self.helper = self.repo / "scripts" / "activate-nixos.sh"
        self.target_script = self.repo / "scripts" / "_activate-nixos" / "activate.sh"
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
            "STUB_CFG_HOSTNAME": self.host,
            "STUB_CLOSURE": str(self.closure),
            "STUB_DRV": str(self.store / f"{HASH}-nixos-system.drv"),
            "NIX_SSHOPTS": "-o ControlPath=/inherited/socket",
        }

    def make_closure(self, host, name=None, etc_host=None, store=None):
        c = (store or self.store) / (name or f"{HASH}-nixos-system-{host}-{VERSION}")
        (c / "bin").mkdir(parents=True, exist_ok=True)
        (c / "etc").mkdir(exist_ok=True)
        (c / "etc" / "hostname").write_text((etc_host or host) + "\n")
        s = c / "bin" / "switch-to-configuration"
        s.write_text(
            "#!/usr/bin/env bash\n"
            'printf "ACTIVATED\\t%s\\n" "$*" >> "$STUB_LOG"\n'
            'exit "${STUB_SWITCH_RC:-0}"\n'
        )
        s.chmod(0o755)
        return c

    def run_helper(self, *args, helper=None, **env):
        return subprocess.run(
            ["bash", str(helper or self.helper), *args],
            env={**self.env, **{k: str(v) for k, v in env.items()}},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=30,
            cwd=self.tmp,
        )

    def run_target_script(self, closure, host="hpp-1", action="switch"):
        return subprocess.run(
            ["bash", str(self.target_script), host, str(closure), action, "0" * 32],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def lines(self, prefix=None):
        rows = [ln.split("\t") for ln in self.log.read_text().splitlines() if ln]
        return [r for r in rows if prefix is None or r[0] == prefix]

    def copies(self):
        return [x for x in self.lines("nix") if x[1].startswith("copy")]

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
        self.assertEqual(self.copies(), [])
        self.assertFalse(self.activated())

    def bad_closures(self):
        outside = self.tmp / "elsewhere"
        return {
            "prefix before nixos-system": self.make_closure(
                "hpp-1", name=f"{HASH}-custom-nixos-system-hpp-1-{VERSION}"
            ),
            "longer hostname": self.make_closure(
                "hpp-1-lab", name=f"{HASH}-nixos-system-hpp-1-lab-{VERSION}"
            ),
            "short hash": self.make_closure(
                "hpp-1", name=f"abc123-nixos-system-hpp-1-{VERSION}"
            ),
            "outside the store": self.make_closure("hpp-1", store=outside),
            "etc/hostname differs": self.make_closure(
                "hpp-1", name=f"{HASH[::-1]}-nixos-system-hpp-1-{VERSION}",
                etc_host="hpp-1-lab",
            ),
        }  # fmt: skip

    def test_lookalike_closures_block_before_copy(self):
        for why, bad in self.bad_closures().items():
            with self.subTest(why):
                self.log.write_text("")
                r = self.run_helper(
                    "--host", "hpp-1", "--dest", "hpp-1", STUB_CLOSURE=bad
                )
                self.assertNotEqual(r.returncode, 0, why)
                self.assertIn("refusing", r.stderr)
                self.assertEqual(self.copies(), [], why)
                self.assertEqual(self.lines("ssh"), [], why)
                self.assertFalse(self.activated(), why)

    def test_target_script_rejects_wrong_closure_on_its_own(self):
        # Defence in depth: even if the local check were bypassed, the script
        # that runs on the target re-asserts the closure name and etc/hostname.
        cases = {"other host": self.make_closure("amos1"), **self.bad_closures()}
        for why, bad in cases.items():
            with self.subTest(why):
                r = self.run_target_script(bad)
                self.assertNotEqual(r.returncode, 0, why)
                self.assertIn("refusing", r.stderr)
                self.assertNotIn("ACTIVATE-NIXOS-VERIFIED", r.stdout)
                self.assertFalse(self.activated(), why)
        ok = self.run_target_script(self.closure)
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_dry_run_checks_the_configured_hostname(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        bad = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--dry-run", STUB_CFG_HOSTNAME="hpp-1-lab"
        )  # fmt: skip
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("configuration is for host 'hpp-1-lab'", bad.stderr)

    def test_identity_checks_share_the_activation_command_chain(self):
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        ssh = self.lines("ssh")
        self.assertEqual(len(ssh), 1, "exactly one connection carries the activation")
        self.assertIn(
            "sudo bash -s -- hpp-1 " + str(self.closure) + " switch ", ssh[0][1]
        )
        script = (self.log.parent / "log.stdin").read_text()
        host_check = script.index('"$actual" = "$host"')
        name_check = script.index("[[ $closure =~ $name_re ]]")
        etc_check = script.index('"$configured" = "$host"')
        switch = script.index('switch-to-configuration" "$action"')
        self.assertLess(host_check, switch)
        self.assertLess(name_check, switch)
        self.assertLess(etc_check, switch)
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

    def test_activation_failure_is_reported_once_and_not_retried(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SWITCH_RC=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not retried", r.stderr)
        self.assertEqual(len(self.lines("ACTIVATED")), 1, "exactly one attempt")
        self.assertEqual(len(self.lines("systemd-run")), 1)
        self.assertEqual(len(self.lines("ssh")), 1)
        self.assertNotIn("ACTIVATE-NIXOS-DONE", r.stdout)

    def test_script_that_never_ran_fails_the_activation(self):
        # e.g. `ssh -n`: sudo bash -s reads empty stdin and exits 0
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SSH_NULL_STDIN=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("never confirmed", r.stderr)
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

    def test_test_action_records_no_generation(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "test")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines("ACTIVATED")[0][1], "test")
        self.assertEqual(self.lines("nix-env"), [], "test must not record a generation")

    def test_boot_action_records_the_generation_then_boots(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "boot")
        self.assertEqual(r.returncode, 0, r.stderr)
        env_calls = self.lines("nix-env")
        self.assertEqual(len(env_calls), 1)
        self.assertEqual(
            env_calls[0][1],
            f"--profile /nix/var/nix/profiles/system --set {self.closure}",
        )
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["boot"])
        rows = [r[0] for r in self.lines() if r[0] in ("nix-env", "ACTIVATED")]
        self.assertEqual(rows, ["nix-env", "ACTIVATED"], "generation recorded first")

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

    def test_ssh_options_outside_the_allowlist_are_refused(self):
        bad = [
            "-n", "-f", "-N", "-T", "-t", "-M", "-Wx:22", "-O", "-Oexit", "-S/tmp/s",
            "-F/tmp/cfg", "-lroot", "-L1:x:2", "-oRemoteCommand=id",
            "-oProxyCommand=nc", "-oUser=root", "-oHostname=amos1",
            "-oStdinNull=yes", "-oPermitLocalCommand=yes", "-o ControlPath=/x",
            "-oControlPath=/a /b", "-oForwardAgent=$(id)", "-oFoo=1",
        ]  # fmt: skip
        for opt in bad:
            for flag in ("--target-ssh-opt", "--build-ssh-opt"):
                with self.subTest(opt=opt, flag=flag):
                    self.log.write_text("")
                    extra = ["--build-host", "b@build1"] if "build" in flag else []
                    r = self.run_helper(
                        "--host", "hpp-1", "--dest", "hpp-1", *extra, f"{flag}={opt}"
                    )  # fmt: skip
                    self.assertNotEqual(r.returncode, 0, opt)
                    self.assertEqual(self.lines(), [], opt)

    def test_allowlisted_ssh_options_keep_argument_boundaries(self):
        opts = ["-oForwardAgent=yes", "-i~/.ssh/id_ed25519", "-Jjump.example", "-4"]
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", *[f"--target-ssh-opt={o}" for o in opts]
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.copies()[0][2], "NIX_SSHOPTS=[" + " ".join(opts) + "]")

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
        cases = [
            ("--dest", "evil; reboot"), ("--host", "Hpp_1"), ("--host", "-x"),
            ("--user", "root;id"), ("--port", "0"), ("--port", "70000"),
            ("--port", "22 -oProxyCommand=x"), ("--action", "switch;id"),
            ("--remote-flake", "../etc"), ("--remote-flake", "/abs"),
        ]  # fmt: skip
        for flag, value in cases:
            with self.subTest(flag=flag, value=value):
                args = {"--host": "hpp-1", "--dest": "hpp-1", flag: value}
                r = self.run_helper(*[x for kv in args.items() for x in kv])
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
        self.assertIn(
            "ipreston@hpp-1 sudo bash -s -- hpp-1 " + str(self.closure) + " switch ",
            [d for d in ssh_dests if "bash -s" in d][0],
        )

    def test_build_host_closure_name_is_checked_before_target_copy(self):
        other = self.make_closure("amos1")
        r = self.run_split(STUB_CLOSURE=other)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(
            [x for x in self.lines("nix") if "--to ssh-ng://ipreston@" in x[1]], []
        )
        self.assertFalse(self.activated())

    def assert_refused_before_any_build(self, r):
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("same ControlPath", r.stderr)
        self.assertEqual(self.copies(), [])
        self.assertEqual([x for x in self.lines("ssh") if "-G" not in x[1].split()], [])
        self.assertFalse(self.activated())

    def test_identical_explicit_controlpath_is_refused(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=/sock/SHARED", "--build-ssh-opt=-oControlPath=/sock/SHARED",
        )  # fmt: skip
        self.assert_refused_before_any_build(r)

    def test_identical_ssh_config_controlpath_is_refused(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            STUB_SSH_CONTROLPATH="/home/u/.ssh/shared-master",
        )  # fmt: skip
        self.assert_refused_before_any_build(r)
        dry = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--dry-run", STUB_SSH_CONTROLPATH="/home/u/.ssh/shared-master",
        )  # fmt: skip
        self.assertNotEqual(dry.returncode, 0)

    def test_multiplexing_disabled_on_both_is_allowed(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=none", "--build-ssh-opt=-oControlPath=none",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.activated())


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
        shutil.copytree(self.repo / "scripts", main / "scripts")
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


class TaskRouting(Harness):
    """The real Task entry points, run end to end against the stubs."""

    def task(self, *argv, **env):
        task = shutil.which("task")
        if task is None:
            self.skipTest("go-task not available")
        return subprocess.run(
            [task, "--silent", *argv],
            cwd=self.repo,
            env={**self.env, **{k: str(v) for k, v in env.items()}},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=60,
        )

    def test_rebuild_activates_this_host_through_the_helper(self):
        r = self.task("rebuild")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines("ssh"), [])
        self.assertIn(
            f"nix-secrets path:{self.tmp}/nix-secrets", self.lines("nix")[0][1]
        )
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["switch"])

    def test_rebuild_host_refuses_a_hostname_mismatch(self):
        r = self.task("rebuild:hpp-1", STUB_HOSTNAME="amos1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected 'hpp-1'", r.stderr)
        self.assertFalse(self.activated())

    def test_deploy_activates_the_named_host_with_action(self):
        r = self.task("deploy:hpp-1", "ACTION=boot")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.copies()[0][1].split()[-2], "ssh-ng://ipreston@hpp-1")
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["boot"])

    def test_bootstrap_rebuild_keeps_host_and_dest_distinct(self):
        (self.repo / "src" / "nixos").mkdir(parents=True)
        r = self.task(
            "bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", "SSH_PORT=2200"
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        ssh = self.lines("ssh")
        self.assertEqual(len(ssh), 2)
        for row in ssh:
            self.assertTrue(
                row[1].startswith("-p 2200 -oForwardAgent=yes ipreston@192.0.2.9 ")
            )
        self.assertIn("--override-input nix-secrets path:../nix-secrets", ssh[0][1])
        self.assertTrue(self.activated())
        self.log.write_text("")
        off = self.task(
            "bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", "LOCAL_SECRETS=false"
        )
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertNotIn("nix-secrets", self.lines("ssh")[0][1])

    def test_shell_metacharacters_never_execute(self):
        marker = self.tmp / "pwned"
        payloads = [
            f"$(touch {marker})", f"`touch {marker}`", f"x;touch {marker}",
            f"x && touch {marker}", f"x | touch {marker}", f"x touch {marker}",
        ]  # fmt: skip
        (self.repo / "src" / "nixos").mkdir(parents=True)
        for p in payloads:
            invocations = [
                (f"deploy:{p}",), (f"rebuild:{p}",), ("rebuild", f"ACTION={p}"),
                ("deploy:hpp-1", f"ACTION={p}"),
                ("bootstrap:rebuild", f"HOST={p}", "DEST=192.0.2.9"),
                ("bootstrap:rebuild", "HOST=hpp-1", f"DEST={p}"),
                ("bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", f"TARGET_USER={p}"),
                ("bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", f"SSH_PORT={p}"),
                ("bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", f"LOCAL_SECRETS={p}"),
            ]  # fmt: skip
            for argv in invocations:
                with self.subTest(argv=argv):
                    self.log.write_text("")
                    marker.unlink(missing_ok=True)
                    r = self.task(*argv)
                    self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertFalse(marker.exists(), f"{argv} executed its payload")
                    self.assertEqual(
                        [x for x in self.lines() if x[0] in ("nix", "ssh", "sudo")], []
                    )

    def test_no_task_activates_without_the_helper(self):
        for f in [REPO / "Taskfile.yaml", *sorted((REPO / "taskfiles").glob("*.yaml"))]:  # fmt: skip
            text = f.read_text()
            for banned in ("nixos-rebuild", "switch-to-configuration"):
                for n, line in enumerate(text.splitlines(), 1):
                    if banned in line and not line.lstrip().startswith(("#", "desc:")):
                        self.fail(f"{f.name}:{n} calls {banned} directly")


if __name__ == "__main__":
    unittest.main(verbosity=2)
