#!/usr/bin/env python3
"""Mocked transport and identity tests for scripts/activate-nixos.sh.

Every external command (nix, ssh, sudo, hostname, nix-env, systemd-run, ...) is
a logging stub on PATH. ssh "connects" by running the remote command string
locally, so the real scripts/_activate-nixos/activate.sh executes end to end,
but nothing ever reaches a real host and no real closure is activated.

usage: activate-nixos-test.py REPO_ROOT
"""

import json
import os
from pathlib import Path
import shlex
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
# The Nix build sandbox has no /usr/bin/env (only /bin/sh), so no shebang here
# may name it: every script this test writes or copies uses the bash that is
# running on PATH, resolved at runtime.
BASH = os.path.realpath(shutil.which("bash") or "/bin/bash")
SHEBANG = f"#!{BASH}\n"
ENV_SHEBANG = "#!/usr/bin/env bash\n"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}
# Per-invocation git settings for fixtures: no hooks, no signing, no templates.
GIT_FLAGS = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]


def controlled_env(home, base=None):
    """The caller's environment minus everything git (or a caller's HOME/XDG
    config) could inject: all GIT_* variables are dropped, HOME and
    XDG_CONFIG_HOME point at an empty temp dir, and global/system git config
    are disabled."""
    env = {
        k: v
        for k, v in (os.environ if base is None else base).items()
        if not k.startswith("GIT_")
    }
    home = Path(home)
    (home / "xdg").mkdir(parents=True, exist_ok=True)
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / "xdg"), **GIT_ENV)
    return env


def git(*args, cwd, env):
    """A fixture git command in a controlled environment."""
    return subprocess.run(
        ["git", *GIT_FLAGS, *args],
        cwd=cwd,
        env=env,
        check=True,
        capture_output=True,
    )


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
  config) printf '%s\n' "${STUB_BUILDERS:-}" ;;
  store)
    if [ "$4" = "${STUB_STORE_URI:-ssh://ipreston@hpp-1}" ]; then
      if [ -n "${STUB_STORE_ERROR:-}" ]; then
        printf '%s\n' "$STUB_STORE_ERROR" >&2
        exit "${STUB_STORE_RC:-1}"
      fi
      exit "${STUB_STORE_RC:-0}"
    fi ;;
esac
""",
    "nix-store": 'log "$@"; echo "$STUB_CLOSURE"',
    "hostname": r"""
echo "$STUB_HOSTNAME"
[ -z "${STUB_LOCAL_HOSTNAME_WARNING:-}" ] || printf '%s\n' "$STUB_LOCAL_HOSTNAME_WARNING" >&2
exit "${STUB_LOCAL_HOSTNAME_RC:-0}"
""",
    "sudo": 'log "$@"; exec "$@"',
    # the store-copy user and its logind state (#1076): STUB_NO_COPY_USER removes
    # the user; STUB_LOGIND_BUSY_POLLS=N makes the first N polls see a session.
    "id": r"""
if [ "$*" = "-u nix-ssh" ]; then
  [ -z "${STUB_NO_COPY_USER:-}" ] || exit 1
  echo 981; exit 0
fi
PATH=${PATH#"$(dirname "$0")":} exec id "$@"
""",
    "loginctl": r"""
log "$@"
n=$(cat "$STUB_LOG.polls" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STUB_LOG.polls"
[ "$n" -lt "${STUB_LOGIND_BUSY_POLLS:-0}" ]
""",
    "systemctl": 'log "$@"; echo inactive',
    "nix-env": 'log "$@"',
    "systemd-run": 'log "$@"; while [ "${1#-}" != "$1" ]; do shift; done; exec "$@"',
    "ssh-add": r"""
printf 'ssh-add\t%s\tSOCKET=[%s]\n' "$*" "${SSH_AUTH_SOCK-}" >> "$STUB_LOG"
case ${STUB_AGENT:-ok} in
  refused) echo 'error fetching identities: agent refused operation' >&2; exit 1 ;;
  empty) echo 'The agent has no identities.' >&2; exit 1 ;;
  hang) trap '' TERM; sleep 90 ;;
  ok) echo '256 SHA256:abcdefg private-comment (ED25519-SK)' ;;
esac
""",
    "ssh": r"""
log "$@"
case " $* " in
  *" -O check "*) exit "${STUB_MASTER_RC:-0}" ;;
  *" -G "*) # effective config: an explicit ControlPath wins, else "ssh_config"
    if [ -n "${STUB_SSH_CONFIG_ERROR:-}" ]; then
      printf '%s\n' "$STUB_SSH_CONFIG_ERROR" >&2
      exit 255
    fi
    cp=${STUB_SSH_CONTROLPATH-}
    for a in "$@"; do case $a in -oControlPath=*) cp=${a#-oControlPath=} ;; esac; done
    [ -z "$cp" ] || printf 'controlpath %s\n' "$cp"
    printf 'controlmaster auto\n'
    [ -z "${STUB_IDENTITY_AGENT:-}" ] || printf 'identityagent %s\n' "$STUB_IDENTITY_AGENT"
    exit 0 ;;
esac
# skip options to find the destination, then run the command string locally
while [ $# -gt 0 ]; do
  case $1 in -p | -o | -i) shift 2 ;; -*) shift ;; *) break ;; esac
done
destination=$1
shift
case "$*" in
  true)
    if [ "$destination" = "${STUB_FAILED_BUILDER:-terra}" ]; then
      if [ -n "${STUB_BUILDER_ERROR:-}" ]; then
        printf '%s\n' "$STUB_BUILDER_ERROR" >&2
        exit "${STUB_BUILDER_RC:-255}"
      fi
      exit "${STUB_BUILDER_RC:-0}"
    fi ;;
  hostname)
    [ -z "${STUB_HOSTNAME_SSH_WARNING:-}" ] || printf '%s\n' "$STUB_HOSTNAME_SSH_WARNING" >&2
    hostname
    exit "${STUB_HOSTNAME_SSH_RC:-$?}" ;;
  'bash -s -- '*)
    [ -z "${STUB_REMOTE_PROBE_WARNING:-}" ] || printf '%s\n' "$STUB_REMOTE_PROBE_WARNING" >&2
    [ -z "${STUB_REMOTE_PROBE_RC:-}" ] || exit "$STUB_REMOTE_PROBE_RC"
    PATH="${STUB_REMOTE_PROBE_PATH:-$PATH}" exec "$BASH" -c "$*" ;;
  'sudo bash -s '*)
    [ -z "${STUB_SSH_RC-}" ] || exit "$STUB_SSH_RC"
    if [ -n "${STUB_SSH_NULL_STDIN-}" ]; then # what `ssh -n` does
      exec bash -c "$*" < /dev/null
    fi
    cat > "$STUB_LOG.stdin" || true
    exec bash -c "$*" < "$STUB_LOG.stdin" ;;
  *) exec bash -c "$*" ;;
esac
""",
}


def make_repo(dest, store, env):
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
    # Hermetic interpreter: swap the /usr/bin/env shebang of every shell script
    # for the resolved bash (a Nix sandbox cannot exec the former).
    for f in (repo / "scripts").rglob("*.sh"):
        text = f.read_text()
        if text.startswith(ENV_SHEBANG):
            f.write_text(SHEBANG + text[len(ENV_SHEBANG) :])
            f.chmod(0o755)
    make_secrets(repo, env)
    # A throwaway git repo, so nothing depends on the caller's checkout (the
    # sandbox copy has no .git).
    for args in (
        ("init", "-q", "--template=", "-b", "main"),
        ("add", "-A"),
        ("commit", "-q", "-m", "init"),
    ):
        git(*args, cwd=repo, env=env)
    return repo


def make_secrets(repo, env):
    secrets = repo.parent / "nix-secrets"
    secrets.mkdir()
    git("init", "-q", "--template=", "-b", "main", cwd=secrets, env=env)
    git("commit", "-q", "--allow-empty", "-m", "locked", cwd=secrets, env=env)
    rev = git("rev-parse", "HEAD", cwd=secrets, env=env).stdout.decode().strip()
    lock = {
        "root": "root",
        "nodes": {
            "root": {"inputs": {"nix-secrets": "nix-secrets_2"}},
            "nix-secrets_2": {"locked": {"rev": rev}},
        },
    }
    (repo / "flake.lock").write_text(json.dumps(lock))
    return secrets


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.store = self.tmp / "store"
        self.store.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.base_env = controlled_env(self.home)
        self.repo = make_repo(self.tmp, self.store, self.base_env)
        self.helper = self.repo / "scripts" / "activate-nixos.sh"
        self.target_script = self.repo / "scripts" / "_activate-nixos" / "activate.sh"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, body in STUBS.items():
            p = self.bin / name
            p.write_text(SHEBANG + LOGGER + body)
            p.chmod(0o755)
        self.log = self.tmp / "log"
        self.log.write_text("")
        self.host = "hpp-1"
        self.closure = self.make_closure(self.host)
        self.env = {
            **self.base_env,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "STUB_HOSTNAME": self.host,
            "STUB_CFG_HOSTNAME": self.host,
            "STUB_CLOSURE": str(self.closure),
            "STUB_DRV": str(self.store / f"{HASH}-nixos-system.drv"),
            "NIX_SSHOPTS": "-o ControlPath=/inherited/socket",
            "SSH_AUTH_SOCK": "/stub/default-agent.sock",
            "STUB_IDENTITY_AGENT": "/stub/effective-agent.sock",
            "STUB_AGENT": "ok",
            "STUB_BUILDERS": "",
        }

    def make_closure(self, host, name=None, etc_host=None, store=None):
        c = (store or self.store) / (name or f"{HASH}-nixos-system-{host}-{VERSION}")
        (c / "bin").mkdir(parents=True, exist_ok=True)
        (c / "etc").mkdir(exist_ok=True)
        (c / "etc" / "hostname").write_text((etc_host or host) + "\n")
        s = c / "bin" / "switch-to-configuration"
        s.write_text(
            f"{SHEBANG}"
            'printf "ACTIVATED\\t%s\\n" "$*" >> "$STUB_LOG"\n'
            '[ -z "${STUB_SWITCH_READS_STDIN-}" ] || cat > /dev/null\n'
            '[ -z "${STUB_SWITCH_OUT-}" ] || printf "%s" "$STUB_SWITCH_OUT"\n'
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

    def operational_ssh(self):
        return [
            row
            for row in self.lines("ssh")
            if not row[1].startswith("-oBatchMode=yes ")
        ]

    def copies(self):
        return [x for x in self.lines("nix") if x[1].startswith("copy")]

    def activated(self):
        return bool(self.lines("ACTIVATED"))


class TransportPreflight(Harness):
    def probe(self, *args, **env):
        return self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--preflight", *args, **env
        )

    def assert_probe_failed(self, result, reason):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stderr)
        self.assertNotIn("private-detail", result.stderr)
        self.assertFalse(self.activated())
        self.assertEqual(self.copies(), [])
        self.assertFalse(
            [row for row in self.lines("nix") if row[1].startswith(("build", "eval"))]
        )

    def test_preflight_only_reuses_the_target_options_and_probes_each_builder(self):
        machines = self.tmp / "builders"
        machines.write_text(
            "# comment\nssh://terra x86_64-linux\n"
            "ssh-ng://builder@build2:2200 x86_64-linux /stub/key\n"
        )
        r = self.probe(
            "--port", "2222", "--target-ssh-opt=-oControlPath=/stub/master",
            "--target-ssh-opt=-oBatchMode=no", STUB_BUILDERS=f"@{machines}",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("IdentityAgent, which differs from SSH_AUTH_SOCK", r.stderr)
        self.assertIn("SHA256:abcdefg (ED25519-SK)", r.stderr)
        self.assertNotIn("private-comment", r.stderr)
        self.assertNotIn("/stub/effective-agent.sock", r.stderr)
        self.assertEqual(
            self.lines("ssh-add")[0][2], "SOCKET=[/stub/effective-agent.sock]"
        )
        ssh = self.lines("ssh")
        self.assertIn("-O check -T ipreston@hpp-1", ssh[0][1])
        self.assertTrue(all(row[1].startswith("-oBatchMode=yes ") for row in ssh))
        self.assertIn(" terra true", ssh[2][1])
        self.assertIn("-i /stub/key -p 2200 -T builder@build2 true", ssh[3][1])
        self.assertTrue(ssh[-1][1].endswith("ipreston@hpp-1 hostname"))
        store, config = self.lines("nix")
        self.assertEqual(store[1], "store info --store ssh://ipreston@hpp-1")
        self.assertIn("-oControlMaster=no -p 2222 -oControlPath=/stub/master", store[2])
        self.assertTrue(store[2].startswith("NIX_SSHOPTS=[-oBatchMode=yes "))
        self.assertEqual(config[1], "config show builders")
        self.assertFalse(self.activated())

    def test_missing_master_blocks_before_the_agent_and_store(self):
        self.assert_probe_failed(self.probe(STUB_MASTER_RC=255), "no usable SSH master")
        self.assertEqual(self.lines("ssh-add"), [])
        self.assertEqual(self.lines("nix"), [])

    def test_bootstrap_without_a_master_still_checks_the_store(self):
        r = self.probe(
            "--remote-flake", "src/nixos",
            STUB_MASTER_RC=255, STUB_STORE_ERROR="protocol mismatch",
        )  # fmt: skip
        self.assertIn("warning: no usable SSH master", r.stderr)
        self.assertIn("SKIP_PREFLIGHT=true or --skip-preflight", r.stderr)
        self.assert_probe_failed(r, "Nix store protocol mismatch")

    def test_ssh_config_failure_stops_before_querying_agent(self):
        r = self.probe(STUB_SSH_CONFIG_ERROR="Bad configuration: private-detail")
        self.assert_probe_failed(
            r, "cannot read effective SSH settings for ipreston@hpp-1"
        )
        self.assertEqual(self.lines("ssh-add"), [])
        self.assertEqual(self.lines("nix"), [])

    def test_remote_hostname_ignores_stderr_on_success(self):
        r = self.probe(STUB_HOSTNAME_SSH_WARNING="Warning: private-detail")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight: passed for hpp-1", r.stderr)
        self.assertNotIn("private-detail", r.stderr)

    def test_local_hostname_ignores_stderr_on_success(self):
        r = self.run_helper(
            "--host", "hpp-1", "--preflight",
            STUB_LOCAL_HOSTNAME_WARNING="Warning: private-detail",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight: passed for hpp-1", r.stderr)
        self.assertNotIn("private-detail", r.stderr)

    def test_preflight_rejects_an_unexpected_hostname(self):
        self.assert_probe_failed(
            self.probe(STUB_HOSTNAME="amos1"), "hostname was 'amos1', expected 'hpp-1'"
        )

    def test_probe_timeouts_are_classified_by_leg(self):
        for code in (124, 137):
            for reason, args, env in (
                ("store transport ssh://ipreston@hpp-1", (), {"STUB_STORE_RC": code}),
                ("store transport ssh-ng://builder@build1", ("--build-host", "builder@build1"),
                 {"STUB_STORE_URI": "ssh-ng://builder@build1", "STUB_STORE_RC": code}),
                ("builder terra", (), {"STUB_BUILDERS": "ssh://terra", "STUB_BUILDER_RC": code}),
                ("builder builder@build1", ("--build-host", "builder@build1"),
                 {"STUB_FAILED_BUILDER": "builder@build1", "STUB_BUILDER_RC": code}),
                ("hostname probe for ipreston@hpp-1", (), {"STUB_HOSTNAME_SSH_RC": code}),
            ):  # fmt: skip
                with self.subTest(code=code, probe=reason):
                    self.log.write_text("")
                    self.assert_probe_failed(
                        self.probe(*args, **env), f"{reason}: probe timed out"
                    )
            with self.subTest(code=code, probe="local hostname"):
                self.log.write_text("")
                r = self.run_helper(
                    "--host", "hpp-1", "--preflight", STUB_LOCAL_HOSTNAME_RC=code
                )
                self.assert_probe_failed(r, "local hostname probe: probe timed out")

    def test_hostname_permission_denied_is_classified_from_stderr(self):
        r = self.probe(
            STUB_HOSTNAME_SSH_WARNING="Permission denied (publickey). private-detail",
            STUB_HOSTNAME_SSH_RC=255,
        )
        self.assert_probe_failed(
            r,
            "hostname probe for ipreston@hpp-1: SSH authentication denied in BatchMode",
        )

    def remote_probe_path(self, missing):
        path = self.tmp / f"remote-without-{missing}"
        path.mkdir()
        for tool in ("bash", "basename", "timeout", "nix", "jq", "git"):
            if tool != missing:
                executable = shutil.which(tool, path=self.env["PATH"])
                self.assertIsNotNone(executable, f"test fixture needs {tool}")
                (path / tool).symlink_to(executable)
        return path

    def test_bootstrap_names_missing_remote_tools(self):
        repo = self.tmp / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
        for tool in ("timeout", "nix", "jq", "git"):
            with self.subTest(tool=tool):
                self.log.write_text("")
                r = self.probe(
                    "--remote-flake", "src/nixos", "--local-secrets",
                    STUB_REMOTE_PROBE_PATH=self.remote_probe_path(tool),
                )  # fmt: skip
                self.assert_probe_failed(
                    r, f"on ipreston@hpp-1: required tool '{tool}' is missing"
                )
                self.assertNotIn("Check flake.lock", r.stderr)

    def test_bootstrap_reports_builder_failure_after_successful_secrets_check(self):
        repo = self.tmp / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
        for message, code, reason in (
            ("Host key verification failed. private-detail", 255, "Host key verification failed"),
            ("Connection refused. private-detail", 255, "unreachable over SSH"),
            ("", 124, "probe timed out"),
            ("", 137, "probe timed out"),
        ):  # fmt: skip
            with self.subTest(message=message, code=code):
                self.log.write_text("")
                r = self.probe(
                    "--remote-flake", "src/nixos", "--local-secrets",
                    STUB_BUILDERS="ssh://terra x86_64-linux",
                    STUB_BUILDER_ERROR=message, STUB_BUILDER_RC=code,
                )  # fmt: skip
                self.assert_probe_failed(
                    r, f"preflight: on ipreston@hpp-1: builder terra: {reason}"
                )
                self.assertNotIn("matches the locked revision", r.stderr)

    def test_bootstrap_reports_stale_secrets_before_checking_builders(self):
        repo = self.tmp / "src" / "nixos"
        repo.mkdir(parents=True)
        secrets = make_secrets(repo, self.base_env)
        git(
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "stale",
            cwd=secrets,
            env=self.base_env,
        )
        r = self.probe(
            "--remote-flake", "src/nixos", "--local-secrets",
            STUB_BUILDERS="ssh://terra x86_64-linux",
            STUB_BUILDER_ERROR="Host key verification failed",
        )  # fmt: skip
        self.assert_probe_failed(
            r, "preflight: on ipreston@hpp-1: stale local nix-secrets"
        )
        self.assertFalse(
            [row for row in self.lines("nix") if row[1] == "config show builders"]
        )

    def test_split_build_environment_reports_its_own_builder_failure(self):
        r = self.probe(
            "--build-host", "builder@build1",
            STUB_REMOTE_PROBE_WARNING="preflight: informational private-detail",
            STUB_BUILDERS="ssh://terra x86_64-linux",
            STUB_BUILDER_ERROR="Host key verification failed",
        )  # fmt: skip
        self.assert_probe_failed(
            r,
            "preflight: on builder@build1: builder terra: Host key verification failed",
        )

    def test_remote_build_environment_classifies_ssh_failure_without_remote_marker(
        self,
    ):
        r = self.probe(
            "--remote-flake", "src/nixos",
            STUB_REMOTE_PROBE_WARNING="preflight: informational private-detail\nPermission denied (publickey)",
            STUB_REMOTE_PROBE_RC=255,
        )  # fmt: skip
        self.assert_probe_failed(
            r,
            "build environment on ipreston@hpp-1: SSH authentication denied in BatchMode",
        )

    def test_bootstrap_with_locked_secrets_works_without_remote_jq(self):
        r = self.probe(
            "--remote-flake", "src/nixos",
            STUB_REMOTE_PROBE_PATH=self.remote_probe_path("jq"),
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight: passed for hpp-1", r.stderr)

    def test_agent_refusal_is_classified(self):
        self.assert_probe_failed(
            self.probe(STUB_AGENT="refused"), "agent refused operation"
        )

    def test_agent_no_identities_is_classified(self):
        self.assert_probe_failed(
            self.probe(STUB_AGENT="empty"), "agent has no identities"
        )

    def test_agent_hang_requires_operator_action(self):
        self.assert_probe_failed(
            self.probe(STUB_AGENT="hang"), "SSH agent unresponsive"
        )

    def test_protocol_mismatch_blocks_check_before_build(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--action", "check",
            STUB_STORE_ERROR="error: protocol mismatch, got 'private-detail'",
        )  # fmt: skip
        self.assert_probe_failed(r, "Nix store protocol mismatch")

    def test_split_host_signing_failure_requires_operator_action(self):
        r = self.probe(
            "--build-host", "builder@build1",
            STUB_STORE_URI="ssh-ng://ipreston@hpp-1",
            STUB_STORE_ERROR="sign_and_send_pubkey: agent refused operation; private-detail\n"
            "error: protocol mismatch",
        )  # fmt: skip
        self.assert_probe_failed(r, "needs touch/PIN")
        self.assertNotIn("Nix store protocol mismatch", r.stderr)
        self.assertTrue(self.lines("nix")[0][1].endswith("ssh-ng://ipreston@hpp-1"))
        self.assertFalse([row for row in self.lines("ssh") if "-O check" in row[1]])

    def test_split_builder_store_failure_names_the_builder_store(self):
        r = self.probe(
            "--build-host", "builder@build1",
            STUB_STORE_URI="ssh-ng://builder@build1",
            STUB_STORE_ERROR="Permission denied (publickey). private-detail",
        )  # fmt: skip
        self.assert_probe_failed(
            r,
            "store transport ssh-ng://builder@build1: SSH authentication denied in BatchMode",
        )
        self.assertEqual(
            [row[1] for row in self.lines("nix") if row[1].startswith("store ")],
            [
                "store info --store ssh-ng://ipreston@hpp-1",
                "store info --store ssh-ng://builder@build1",
            ],
        )

    def test_split_host_preflights_both_stores_with_isolated_options(self):
        r = self.probe(
            "--build-host", "builder@build1",
            "--target-ssh-opt=-oIdentityAgent=~/target-agent",
            "--build-ssh-opt=-oIdentityAgent=~/builder-agent",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        target, builder = [x for x in self.lines("nix") if x[1].startswith("store ")]
        self.assertTrue(target[1].endswith("ssh-ng://ipreston@hpp-1"))
        self.assertTrue(builder[1].endswith("ssh-ng://builder@build1"))
        for row, good, forbidden in (
            (target, "target-agent", "builder-agent"),
            (builder, "builder-agent", "target-agent"),
        ):
            self.assertIn("-oBatchMode=yes", row[2])
            self.assertIn("-oControlPath=none", row[2])
            self.assertIn(f"-oIdentityAgent=~/{good}", row[2])
            self.assertNotIn(forbidden, row[2])
        self.assertFalse(self.copies())

    def test_builder_host_key_failure_aborts_before_building(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1",
            STUB_BUILDERS="ssh://terra x86_64-linux",
            STUB_BUILDER_ERROR="Host key verification failed. private-detail",
        )  # fmt: skip
        self.assert_probe_failed(r, "builder terra: Host key verification failed")

    def test_builder_unreachable_aborts_before_building(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1",
            STUB_BUILDERS="ssh://terra x86_64-linux",
            STUB_BUILDER_ERROR="ssh: connect to host terra port 22: Connection refused",
        )  # fmt: skip
        self.assert_probe_failed(r, "builder terra: unreachable over SSH")

    def test_stale_local_secrets_report_dirty_state_only_with_override(self):
        secrets = self.tmp / "nix-secrets"
        git(
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "stale",
            cwd=secrets,
            env=self.base_env,
        )
        (secrets / "private-detail").write_text("secret contents")
        r = self.probe("--local-secrets")
        self.assert_probe_failed(r, "stale local nix-secrets (has uncommitted changes)")
        self.assertIn("differs from locked", r.stderr)
        self.assertEqual(self.probe().returncode, 0)

    def test_matching_local_secrets_report_uncommitted_changes_without_paths(self):
        (self.tmp / "nix-secrets" / "private-detail").write_text("secret contents")
        r = self.probe("--local-secrets")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("matches the locked revision (has uncommitted changes)", r.stderr)
        self.assertNotIn("private-detail", r.stderr)

    def test_explicit_skip_preserves_the_build_path(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--skip-preflight",
            STUB_MASTER_RC=255, STUB_AGENT="empty",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight: skipped (explicit)", r.stderr.splitlines())
        self.assertEqual(self.lines("ssh"), self.operational_ssh())
        self.assertEqual(self.lines("ssh-add"), [])
        self.assertEqual(
            [row[1].split()[0] for row in self.lines("nix")], ["build", "copy"]
        )


class RemoteActivation(Harness):
    def test_success_runs_build_copy_activate_in_order(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        order = [row[0] + ":" + row[1].split(" ")[0] for row in self.lines()]
        build = order.index("nix:build")
        self.assertLess(order.index("nix:store"), build)
        self.assertEqual(order[build : build + 3], ["nix:build", "nix:copy", "ssh:-T"])
        self.assertTrue(self.operational_ssh()[0][1].startswith("-T ipreston@hpp-1 "))
        self.assertTrue(self.activated())
        self.assertEqual(self.lines("nix-env")[0][1].split()[-1], str(self.closure))
        # the requested action is what switch-to-configuration receives
        self.assertEqual(self.lines("ACTIVATED")[0][1], "switch")

    def test_inherited_nix_sshopts_is_discarded(self):
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        for row in self.lines("nix") + self.lines("ssh"):
            self.assertNotIn("/inherited/socket", row[2])

    def test_hostname_mismatch_blocks_activation(self):
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "hpp-1",
            "--skip-preflight",
            STUB_HOSTNAME="amos1",
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected 'hpp-1'", r.stderr)
        self.assertFalse(self.activated())
        self.assertEqual(self.lines("nix-env"), [])
        self.assertEqual(self.lines("systemd-run"), [])

    def test_closure_name_mismatch_blocks_before_copy(self):
        other = self.make_closure("amos1")
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_CLOSURE=other)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.operational_ssh(), [])
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
                self.assertEqual(self.operational_ssh(), [], why)
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
        ssh = self.operational_ssh()
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
        self.assertEqual(len(self.operational_ssh()), 1)
        self.assertFalse(self.activated())

    def test_copy_failure_stops_before_activation(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_COPY_RC=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.operational_ssh(), [])
        self.assertFalse(self.activated())

    def test_lingering_copy_session_is_waited_out_before_activation(self):
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "hpp-1",
            STUB_LOGIND_BUSY_POLLS=3,
            ACTIVATE_SETTLE_INTERVAL=0.05,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("waiting for the nix-ssh session", r.stderr)
        self.assertEqual(len(self.lines("loginctl")), 4, "3 busy polls, then clear")
        self.assertEqual(len(self.lines("ACTIVATED")), 1)
        self.assertEqual(
            len(self.operational_ssh()), 1, "waiting opens no extra connection"
        )

    def test_no_copy_session_means_no_wait(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("waiting", r.stderr)
        self.assertEqual(len(self.lines("loginctl")), 1, "one poll, no wait")
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_NO_COPY_USER=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.lines("loginctl")), 1, "no user, no poll")
        self.assertEqual(len(self.lines("ACTIVATED")), 2)

    def test_copy_session_that_never_ends_fails_before_activation(self):
        r = self.run_helper(
            "--host",
            "hpp-1",
            "--dest",
            "hpp-1",
            STUB_LOGIND_BUSY_POLLS=100000,
            ACTIVATE_SETTLE_TIMEOUT=1,
            ACTIVATE_SETTLE_INTERVAL=0.05,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("did not end", r.stderr)
        self.assertIn("safe to retry", r.stderr)
        self.assertNotIn("failed (not retried)", r.stderr)
        self.assertFalse(self.activated())
        self.assertEqual(self.lines("nix-env"), [], "profile untouched")
        self.assertEqual(self.lines("systemd-run"), [])
        self.assertEqual(len(self.operational_ssh()), 1)
        self.assertNotIn("ACTIVATE-NIXOS-DONE", r.stdout)

    def test_activation_failure_is_reported_once_and_not_retried(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SWITCH_RC=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not retried", r.stderr)
        self.assertEqual(len(self.lines("ACTIVATED")), 1, "exactly one attempt")
        self.assertEqual(len(self.lines("systemd-run")), 1)
        self.assertEqual(len(self.operational_ssh()), 1)
        self.assertNotIn("ACTIVATE-NIXOS-DONE", r.stdout)

    def test_script_that_never_ran_fails_the_activation(self):
        # e.g. `ssh -n`: sudo bash -s reads empty stdin and exits 0
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SSH_NULL_STDIN=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("never confirmed", r.stderr)
        self.assertFalse(self.activated())

    def sentinel_lines(self, r):
        return [ln for ln in r.stdout.splitlines() if ln.startswith("ACTIVATE-NIXOS-")]

    def test_activation_that_reads_stdin_cannot_swallow_the_final_marker(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", STUB_SWITCH_READS_STDIN=1
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.sentinel_lines(r)), 2, r.stdout)
        self.assertTrue(self.activated())

    def test_activation_output_without_newline_cannot_fuse_with_a_marker(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", STUB_SWITCH_OUT="partial line"
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.sentinel_lines(r)), 2, r.stdout)
        self.assertNotIn("partial line", r.stdout)
        self.assertIn("partial line", r.stderr)

    def test_activation_failure_status_survives_the_redirects(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", STUB_SWITCH_RC=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("ACTIVATE-NIXOS-DONE", r.stdout)

    def test_missing_closure_is_allowed_only_for_a_caller_verified_check(self):
        gone = self.store / f"{HASH}-nixos-system-hpp-1-{VERSION}"
        shutil.rmtree(gone)

        def run(action, *extra):
            return subprocess.run(
                [
                    "bash",
                    str(self.target_script),
                    "hpp-1",
                    str(gone),
                    action,
                    "0" * 32,
                    *extra,
                ],
                env=self.env,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
            )

        self.assertNotEqual(run("check").returncode, 0)
        self.assertNotEqual(run("switch", "caller-verified").returncode, 0)
        self.assertEqual(run("check", "caller-verified").returncode, 0)

    def test_helper_marks_remote_check_as_caller_verified(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "check")
        self.assertEqual(r.returncode, 0, r.stderr)
        bash_s = [x for x in self.lines("ssh") if "bash -s" in x[1]]
        self.assertTrue(bash_s[0][1].endswith(" caller-verified"), bash_s)
        self.log.write_text("")
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        bash_s = [x for x in self.lines("ssh") if "bash -s" in x[1]]
        self.assertNotIn("caller-verified", bash_s[0][1])

    def test_check_action_activates_and_copies_nothing(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--action", "check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.activated())
        self.assertEqual(
            [x[1].split()[0] for x in self.lines("nix")], ["store", "config", "build"]
        )
        self.assertEqual(self.copies(), [])
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

    # Single-host copies must reuse the user's pre-opened ssh master (hardware
    # key auth cannot be answered by an agent). ssh-ng:// always starts Nix's
    # own master, so single-host mode copies over the legacy ssh:// store, with
    # only ControlMaster=no (never become a master) ahead of caller options, and
    # never ControlPath=none, which would defeat reuse of the existing socket.
    COPY_FORCED = ["-oControlMaster=no"]

    def test_single_host_copy_uses_ssh_store_and_never_disables_controlpath(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        cp = self.copies()[0]
        self.assertEqual(
            cp[1].split()[-2:], ["ssh://ipreston@hpp-1", str(self.closure)]
        )
        self.assertNotIn("ssh-ng", cp[1])
        self.assertNotIn("ControlPath", cp[2])
        # a caller-pinned socket is still honoured
        self.log.write_text("")
        self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1",
            "--target-ssh-opt=-oControlPath=/sock/CALLER",
        )  # fmt: skip
        self.assertIn("-oControlPath=/sock/CALLER", self.copies()[0][2])
        self.assertNotIn("-oControlPath=none", self.copies()[0][2])

    def test_single_host_copy_forces_no_master_first(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--port", "2222",
            "--target-ssh-opt=-oControlPath=/sock/CALLER",
            "--target-ssh-opt=-oControlMaster=auto",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        nixopts = self.copies()[0][2]
        self.assertTrue(
            nixopts.startswith("NIX_SSHOPTS=[" + " ".join(self.COPY_FORCED) + " "),
            nixopts,
        )
        # ssh keeps the first value it sees, so the caller's cannot win
        words = nixopts.removeprefix("NIX_SSHOPTS=[").removesuffix("]").split()
        self.assertNotIn("-oControlPath=none", words)
        self.assertIn("-oControlPath=/sock/CALLER", words)
        self.assertLess(
            words.index("-oControlMaster=no"), words.index("-oControlMaster=auto")
        )
        # no duplicates of the forced options without a caller
        self.log.write_text("")
        self.run_helper("--host", "hpp-1", "--dest", "hpp-1")
        self.assertEqual(
            self.copies()[0][2], "NIX_SSHOPTS=[" + " ".join(self.COPY_FORCED) + "]"
        )

    def test_dry_run_single_host_shows_ssh_store_copy(self):
        r = self.run_helper("--host", "hpp-1", "--dest", "hpp-1", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("nix copy --to ssh://ipreston@hpp-1", r.stdout)
        self.assertIn("NIX_SSHOPTS=" + " ".join(self.COPY_FORCED), r.stdout)
        self.assertNotIn("ControlPath=none", r.stdout)
        self.assertNotIn("ssh-ng", r.stdout)

    def test_dry_run_check_plan_says_copy_is_skipped(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--action", "check", "--dry-run"
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("plan: copy: skipped (check)", r.stdout)
        self.assertNotIn("nix copy", r.stdout)

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
        self.assertIn("--to ssh://ipreston@10.0.0.5", cp[1])
        self.assertTrue(
            self.operational_ssh()[0][1].startswith(
                "-p 2222 -oForwardAgent=yes -T ipreston@10.0.0.5"
            )
        )

    def test_ssh_options_outside_the_allowlist_are_refused(self):
        bad = [
            "-n", "-f", "-N", "-T", "-t", "-M", "-Wx:22", "-O", "-Oexit", "-S/tmp/s",
            "-F/tmp/cfg", "-lroot", "-L1:x:2", "-oRemoteCommand=id",
            "-oProxyCommand=nc", "-oUser=root", "-oHostname=amos1",
            "-oStdinNull=yes", "-oPermitLocalCommand=yes", "-o ControlPath=/x",
            "-oControlPath=/a /b", "-oForwardAgent=$(id)", "-oFoo=1",
            "-tt", "-oRequestTTY=force", "-orequesttty=yes",
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
        self.assertEqual(
            self.copies()[0][2],
            "NIX_SSHOPTS=[" + " ".join([*self.COPY_FORCED, *opts]) + "]",
        )

    def test_single_host_mode_accepts_jump_hosts(self):
        for opt in ("-Jjump.example", "-oProxyJump=jump.example"):
            with self.subTest(opt=opt):
                self.log.write_text("")
                r = self.run_helper(
                    "--host", "hpp-1", "--dest", "hpp-1", f"--target-ssh-opt={opt}"
                )  # fmt: skip
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(opt, self.lines("ssh")[0][1].split())
                self.assertTrue(self.activated())

    def test_target_ssh_never_allocates_a_tty(self):
        # -T on every target ssh, after the caller's options, so neither
        # `RequestTTY force` in ssh_config nor an option can re-enable a tty
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--target-ssh-opt=-oForwardAgent=yes"
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        ssh = self.lines("ssh")
        self.assertTrue(ssh)
        for row in ssh:
            argv = row[1].split()
            dest = argv.index("ipreston@hpp-1")
            self.assertEqual(argv[dest - 1], "-T", argv)
            self.assertFalse(
                [a for a in argv[:dest] if a.startswith("-t")]
                or [a for a in argv[:dest] if "requesttty" in a.lower()],
                argv,
            )

    def test_remote_flake_builds_and_activates_on_the_same_target_only(self):
        repo = self.tmp / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
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
        self.assertEqual(
            [x[1].split()[0] for x in self.lines("nix")], ["store", "config", "build"]
        )
        self.assertIn("local nix-secrets on ipreston@10.0.0.5 matches", r.stderr)
        ssh = self.operational_ssh()
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
        ssh_dests = [r[1] for r in self.operational_ssh()]
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

    FORCED = [
        "-oControlMaster=no", "-oControlPath=none",
        "-oProxyJump=none", "-oProxyCommand=none",
    ]  # fmt: skip

    def split_rows(self):
        """Every ssh and every nix copy that touches a host, with its options."""
        rows = []
        for r in self.operational_ssh():
            rows.append((r[0], r[1].split(), r[2]))
        for r in self.lines("nix"):
            if r[1].startswith("copy"):
                rows.append((r[0], r[1].split(), r[2]))
        return rows

    def assert_isolated_everywhere(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.split_rows()
        # build ssh, derivation copy, pull, push, activation ssh: five legs
        self.assertGreaterEqual(len(rows), 5, rows)
        for cmd, argv, nixopts in rows:
            if cmd == "ssh":
                # forced options are the first -o options ssh sees (first wins)
                opts = [a for a in argv if a.startswith("-o")]
                self.assertEqual(opts[:4], self.FORCED, argv)
            else:
                self.assertTrue(
                    nixopts.startswith("NIX_SSHOPTS=[" + " ".join(self.FORCED)),
                    nixopts,
                )
        self.assertTrue(self.activated())

    def test_every_split_host_connection_forces_no_multiplexing(self):
        self.assert_isolated_everywhere(self.run_split())

    def test_identical_controlpaths_are_overridden_not_compared(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=/sock/SHARED", "--build-ssh-opt=-oControlPath=/sock/SHARED",
        )  # fmt: skip
        self.assert_isolated_everywhere(r)

    def test_aliased_and_ssh_config_controlpaths_cannot_survive(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=/tmp/shared.sock", "--build-ssh-opt=-oControlPath=/tmp/./shared.sock",
            STUB_SSH_CONTROLPATH="/home/u/.ssh/shared-master",
        )  # fmt: skip
        self.assert_isolated_everywhere(r)

    def test_explicit_jump_hosts_are_refused_in_split_mode(self):
        jumps = [
            "-Jjump.example",
            "-oProxyJump=jump.example",
            "-oproxyjump=j",
            "-JNone",
        ]
        for opt in jumps:
            for flag in ("--target-ssh-opt", "--build-ssh-opt"):
                with self.subTest(opt=opt, flag=flag):
                    self.log.write_text("")
                    r = self.run_helper(
                        "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
                        f"{flag}={opt}",
                    )  # fmt: skip
                    self.assertNotEqual(r.returncode, 0, opt)
                    self.assertIn("jump host", r.stderr)
                    self.assertEqual(self.lines(), [], opt)
                    self.assertFalse(self.activated())

    def test_config_supplied_jumps_are_disabled_on_every_split_leg(self):
        # ProxyJump/ProxyCommand from ~/.ssh/config lose to the forced
        # command-line =none values on every leg, nix copy transports included
        r = self.run_split()
        self.assert_isolated_everywhere(r)
        for cmd, argv, nixopts in self.split_rows():
            text = " ".join(argv) if cmd == "ssh" else nixopts
            self.assertIn("-oProxyJump=none -oProxyCommand=none", text)

    def test_controlpath_with_a_space_cannot_reach_ssh(self):
        # whitespace in an option is refused outright, before anything runs
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1",
            "--target-ssh-opt=-oControlPath=/tmp/a b", "--build-ssh-opt=-oControlPath=/tmp/a",
        )  # fmt: skip
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.split_rows(), [])
        self.assertFalse(self.activated())

    def test_single_host_never_disables_multiplexing_anywhere(self):
        # the pre-opened master must stay usable by the copy and the activation
        for action in ("switch", "check"):
            self.log.write_text("")
            r = self.run_helper(
                "--host", "hpp-1", "--dest", "hpp-1", "--action", action
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            rows = self.split_rows()
            self.assertTrue(rows)
            for cmd, argv, nixopts in rows:
                self.assertNotIn("-oControlPath=none", argv)
                self.assertNotIn("ControlPath=none", nixopts)

    def test_split_host_copies_still_use_ssh_ng_with_isolation(self):
        r = self.run_split()
        self.assertEqual(r.returncode, 0, r.stderr)
        push = [x for x in self.copies() if "--to ssh-ng://ipreston@hpp-1" in x[1]]
        self.assertEqual(len(push), 1, self.copies())
        self.assertTrue(push[0][2].startswith("NIX_SSHOPTS=[" + " ".join(self.FORCED)))

    def test_dry_run_split_host_shows_forced_options(self):
        r = self.run_helper(
            "--host", "hpp-1", "--dest", "hpp-1", "--build-host", "builder@build1", "--dry-run",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(" ".join(self.FORCED), r.stdout)


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

        def g(*a, cwd=main):
            git(*a, cwd=cwd, env=self.base_env)

        g("init", "-q", "--template=", "-b", "main")
        g("add", "-A")
        g("commit", "-q", "-m", "init")
        wt = src / "nixos-worktrees" / "wt"
        g("worktree", "add", "-q", str(wt), "-b", "feature")
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
        self.assertNotIn("nix-secrets", " ".join(x[1] for x in self.lines("nix")))
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["switch"])

    def nix_args(self):
        return " ".join(x[1] for x in self.lines("nix"))

    def test_routine_tasks_resolve_nix_secrets_from_the_lock_by_default(self):
        # No sibling checkout at all: the default must not need one (#1042).
        shutil.rmtree(self.tmp / "nix-secrets")
        for argv in (("rebuild",), ("rebuild:hpp-1",), ("deploy:hpp-1",)):
            with self.subTest(argv=argv):
                self.log.write_text("")
                r = self.task(*argv)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(self.activated())
                self.assertNotIn("nix-secrets", self.nix_args())
                self.assertNotIn("--override-input", self.nix_args())

    def test_local_secrets_true_opts_routine_tasks_into_the_sibling_checkout(self):
        for argv in (("rebuild",), ("rebuild:hpp-1",), ("deploy:hpp-1",)):
            with self.subTest(argv=argv):
                self.log.write_text("")
                r = self.task(*argv, "LOCAL_SECRETS=true")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(
                    f"--override-input nix-secrets path:{self.tmp}/nix-secrets",
                    self.nix_args(),
                )
                self.log.write_text("")
                r = self.task(*argv, "LOCAL_SECRETS=false")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("nix-secrets", self.nix_args())

    def test_local_secrets_true_without_a_sibling_checkout_fails_before_building(self):
        shutil.rmtree(self.tmp / "nix-secrets")
        r = self.task("deploy:hpp-1", "LOCAL_SECRETS=true")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nix-secrets", r.stderr)
        self.assertFalse(self.activated())

    def test_invalid_local_secrets_is_rejected_before_anything_runs(self):
        for value in ("yes", "1", "TRUE", "maybe", ""):
            for argv in (
                ("rebuild",),
                ("rebuild:hpp-1",),
                ("deploy:hpp-1",),
                ("hashes",),
            ):
                with self.subTest(argv=argv, value=value):
                    self.log.write_text("")
                    r = self.task(*argv, f"LOCAL_SECRETS={value}")
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn("LOCAL_SECRETS must be true or false", r.stderr)
                    self.assertEqual(
                        [x for x in self.lines() if x[0] in ("nix", "ssh", "sudo")], []
                    )

    def test_hashes_uses_the_lock_unless_local_secrets_is_true(self):
        regen = self.repo / "scripts" / "regen-fetch-hashes.sh"
        out = self.tmp / "regen-args"
        # one NUL-terminated record per argument, then the inherited variable
        regen.write_text(
            f"{SHEBANG}"
            f'{{ printf "%s\\0" "$@"; printf "ARGS=[%s]\\0" "${{REGEN_NIX_ARGS-}}"; }} > {shlex.quote(str(out))}\n'
        )
        regen.chmod(0o755)
        inherited = "--override-input nix-secrets path:/stale/checkout"
        local = "--override-input nix-secrets path:../nix-secrets"
        for value, expected in (
            (None, ""),
            ("false", ""),
            ("true", local),
        ):
            with self.subTest(value=value):
                out.unlink(missing_ok=True)
                argv = ["hashes", "--", "--check", "with space.nix"]
                if value:
                    argv.insert(1, f"LOCAL_SECRETS={value}")
                # an inherited REGEN_NIX_ARGS must never reach nix unasked
                r = self.task(*argv, REGEN_NIX_ARGS=inherited)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(
                    out.read_text().split("\0")[:-1],
                    ["--check", "with space.nix", f"ARGS=[{expected}]"],
                )

    def test_regen_script_survives_empty_nix_args_under_old_bash(self):
        # macOS ships bash 3.2, where expanding an empty array under `set -u`
        # is an error; run the real script with the system bash when present.
        bash = "/bin/bash" if Path("/bin/bash").exists() else shutil.which("bash")
        hashval = "sha256-" + "B" * 43 + "="
        nix = self.bin / "nix"
        calls = self.tmp / "nix-calls"
        q_calls = shlex.quote(str(calls))
        nix.write_text(
            f"{SHEBANG}"
            f'printf "%s\\0" "$@" >> {q_calls}; printf "\\n" >> {q_calls}\n'
            f'echo "error: hash mismatch"; echo "  got:    {hashval}"; exit 1\n'
        )
        (self.bin / "nix-prefetch-url").write_text(f"{SHEBANG}exit 1\n")
        (self.bin / "nix-prefetch-url").chmod(0o755)
        target = self.tmp / "with space.nix"
        target.write_text(f'# regen-hash: pkg\nhash = "{hashval}";\n')
        script = self.repo / "scripts" / "regen-fetch-hashes.sh"
        env = {k: v for k, v in self.env.items() if k != "REGEN_NIX_ARGS"}
        for extra, expected in (
            ({}, ""),
            (
                {"REGEN_NIX_ARGS": "--override-input nix-secrets path:/x"},
                "--override-input\0nix-secrets\0path:/x\0",
            ),
        ):
            with self.subTest(regen_nix_args=extra):
                calls.unlink(missing_ok=True)
                r = subprocess.run(
                    [bash, str(script), "--check", str(target)],
                    env={**env, **extra},
                    cwd=self.tmp,
                    capture_output=True,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    timeout=30,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("unbound variable", r.stderr)
                self.assertEqual(
                    calls.read_text(), f"build\0--no-link\0{expected}.#pkg\0\n"
                )

    def test_rebuild_host_refuses_a_hostname_mismatch(self):
        r = self.task("rebuild:hpp-1", STUB_HOSTNAME="amos1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected 'hpp-1'", r.stderr)
        self.assertFalse(self.activated())

    def activation_tasks(self):
        return (
            ("rebuild",),
            ("rebuild:hpp-1",),
            ("deploy:hpp-1",),
            (
                "bootstrap:rebuild",
                "HOST=hpp-1",
                "DEST=192.0.2.9",
                "LOCAL_SECRETS=false",
            ),
        )

    def test_skip_preflight_through_each_activation_task(self):
        (self.repo / "src" / "nixos").mkdir(parents=True)
        for argv in self.activation_tasks():
            for skip in ("true", "false"):
                with self.subTest(argv=argv, skip=skip):
                    self.log.write_text("")
                    r = self.task(*argv, f"SKIP_PREFLIGHT={skip}")
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(
                        "preflight: passed for hpp-1" in r.stderr, skip == "false"
                    )
                    self.assertEqual(
                        "preflight: skipped (explicit)" in r.stderr.splitlines(),
                        skip == "true",
                    )
                    self.assertEqual(
                        "config show builders" in self.nix_args(), skip == "false"
                    )
                    self.assertTrue(self.activated())

        self.log.write_text("")
        r = self.task("deploy:hpp-1", "LOCAL_SECRETS=true", SKIP_PREFLIGHT="true")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight: skipped (explicit)", r.stderr.splitlines())
        self.assertIn("--override-input nix-secrets", self.nix_args())
        self.assertNotIn("config show builders", self.nix_args())

    def test_invalid_skip_preflight_is_rejected_before_probing(self):
        for argv in self.activation_tasks():
            for value in ("", "TRUE", "yes", "1"):
                with self.subTest(argv=argv, value=value):
                    r = self.task(*argv, f"SKIP_PREFLIGHT={value}")
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn("SKIP_PREFLIGHT must be true or false", r.stderr)
                    self.assertEqual(self.lines(), [])

    def test_ssh_preflight_task_runs_only_the_probes(self):
        r = self.task("ssh:preflight", "HOST=hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            [row[1] for row in self.lines("nix")],
            ["store info --store ssh://ipreston@hpp-1", "config show builders"],
        )
        self.assertEqual(self.operational_ssh(), [])
        self.assertFalse(self.activated())

    def test_deploy_activates_the_named_host_with_action(self):
        r = self.task("deploy:hpp-1", "ACTION=boot")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.copies()[0][1].split()[-2], "ssh://ipreston@hpp-1")
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["boot"])

    def test_bootstrap_rebuild_keeps_host_and_dest_distinct(self):
        repo = self.repo / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
        r = self.task(
            "bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", "SSH_PORT=2200",
            STUB_MASTER_RC=255,
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("warning: no usable SSH master for ipreston@192.0.2.9", r.stderr)
        self.assertIn("preflight: passed for hpp-1", r.stderr)
        ssh = self.operational_ssh()
        self.assertEqual(len(ssh), 2)
        for row in ssh:
            self.assertTrue(
                row[1].startswith("-p 2200 -oForwardAgent=yes -T ipreston@192.0.2.9 ")
            )
        self.assertIn("--override-input nix-secrets path:../nix-secrets", ssh[0][1])
        self.assertTrue(self.activated())
        self.log.write_text("")
        off = self.task(
            "bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", "LOCAL_SECRETS=false"
        )
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertNotIn("nix-secrets", self.operational_ssh()[0][1])

    def test_shell_metacharacters_never_execute(self):
        marker = self.tmp / "pwned"
        payloads = [
            f"$(touch {marker})", f"`touch {marker}`", f"x;touch {marker}",
            f"x && touch {marker}", f"x | touch {marker}", f"x touch {marker}",
        ]  # fmt: skip
        repo = self.repo / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
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

    def test_inherited_activate_variables_cannot_redirect_or_change_the_action(self):
        repo = self.repo / "src" / "nixos"
        repo.mkdir(parents=True)
        make_secrets(repo, self.base_env)
        hostile = {
            "ACTIVATE_HOST": "amos1", "ACTIVATE_DEST": "amos1", "ACTIVATE_ACTION": "switch",
            "ACTIVATE_USER": "root", "ACTIVATE_PORT": "1", "ACTIVATE_LOCAL_SECRETS": "false",
            "HOST": "amos1", "DEST": "amos1",
        }  # fmt: skip
        r = self.task("deploy:hpp-1", **hostile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.copies()[0][1].split()[-2], "ssh://ipreston@hpp-1")
        self.assertEqual([x[1] for x in self.lines("ACTIVATED")], ["switch"])
        self.assertFalse([x for x in self.lines() if "amos1" in "".join(x)])
        # an inherited ACTIVATE_ACTION must not turn `check` into a switch
        self.log.write_text("")
        r = self.task("deploy:hpp-1", "ACTION=check", **hostile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.activated())
        r = self.task("rebuild:hpp-1", "ACTION=check", **hostile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.activated())
        r = self.task("rebuild", "ACTION=check", **hostile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.activated())
        self.log.write_text("")
        r = self.task("bootstrap:rebuild", "HOST=hpp-1", "DEST=192.0.2.9", **hostile)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.operational_ssh()
        self.assertTrue(rows)
        for row in rows:
            self.assertTrue(
                row[1].startswith("-p 22 -oForwardAgent=yes -T ipreston@192.0.2.9 ")
            )
        self.assertFalse([x for x in self.lines() if "amos1" in "".join(x)])

    def test_no_task_activates_without_the_helper(self):
        for f in [REPO / "Taskfile.yaml", *sorted((REPO / "taskfiles").glob("*.yaml"))]:  # fmt: skip
            text = f.read_text()
            for banned in ("nixos-rebuild", "switch-to-configuration"):
                for n, line in enumerate(text.splitlines(), 1):
                    if banned in line and not line.lstrip().startswith(("#", "desc:")):
                        self.fail(f"{f.name}:{n} calls {banned} directly")


class HostileGitEnvironment(unittest.TestCase):
    """The fixtures and the helper's own git lookups must not depend on the
    caller's git state: rerun the git-using suites with hostile GIT_* injected."""

    def test_suites_pass_under_injected_git_state(self):
        if os.environ.get("ACTIVATE_TEST_NESTED"):
            self.skipTest("already the nested run")
        with tempfile.TemporaryDirectory() as d:
            gitconfig = Path(d) / "gitconfig"
            gitconfig.write_text(
                "[commit]\n\tgpgsign = true\n[init]\n\ttemplateDir = /nonexistent\n"
            )
            env = {
                **os.environ,
                "ACTIVATE_TEST_NESTED": "1",
                "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "commit.gpgsign",
                "GIT_CONFIG_VALUE_0": "true",
                "GIT_CONFIG_KEY_1": "core.hooksPath",
                "GIT_CONFIG_VALUE_1": "/nonexistent",
                "GIT_CONFIG_PARAMETERS": "'commit.gpgsign=true'",
                "GIT_CONFIG_GLOBAL": str(gitconfig),
                "GIT_DIR": str(Path(d) / "elsewhere.git"),
                "GIT_WORK_TREE": str(Path(d) / "elsewhere"),
                "GIT_INDEX_FILE": str(Path(d) / "elsewhere.index"),
                "GIT_TEMPLATE_DIR": "/nonexistent",
                "GIT_AUTHOR_NAME": "hostile",
                "HOME": d,
                "XDG_CONFIG_HOME": d,
            }
            r = subprocess.run(
                [sys.executable, __file__, str(REPO), "LocalSecrets", "Harness",
                 "BuildHost.test_split_host_copies_still_use_ssh_ng_with_isolation"],
                env=env, capture_output=True, text=True, timeout=300,
            )  # fmt: skip
            self.assertEqual(r.returncode, 0, r.stderr[-3000:])
            self.assertIn("OK", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
