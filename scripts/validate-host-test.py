#!/usr/bin/env python3
"""Offline tests for scripts/validate-host.py (#1063).

The activation helper, nix, ssh and the target's hostname/systemctl/readlink
are logging stubs on PATH. ssh "connects" by running its command locally, so
the real scripts/_validate-host/remote.sh executes end to end; nothing ever
reaches a real host and nothing is activated.

usage: validate-host-test.py REPO_ROOT
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parent.parent
)
# The Nix build sandbox has no /usr/bin/env: stubs use the running bash.
BASH = os.path.realpath(shutil.which("bash") or "/bin/bash")
SHEBANG = f"#!{BASH}\n"
GIT_FLAGS = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}

HASH_OLD = "abcdfghijklmnpqrsvwxyz0123456789"
HASH_NEW = "0123456789abcdfghijklmnpqrsvwxyz"
OLD = f"/nix/store/{HASH_OLD}-nixos-system-hpp-1-26.05.20261101.aaaaaaa"
NEW = f"/nix/store/{HASH_NEW}-nixos-system-hpp-1-26.05.20261115.b349185"
SECRETS_REV = "1" * 40
ENVS = {"hpp-1": "dev", "tests-server": "dev", "amos1": "prod", "terra": None}

LOGGER = r"""
log() { printf '%s\t%s\tNIX_SSHOPTS=[%s]\n' "$(basename "$0")" "$*" "${NIX_SSHOPTS-}" >> "$STUB_LOG"; }
"""

STUBS = {
    # Only `nix eval --json <flake>#nixosConfigurations.<h>._module.specialArgs.hostSpec.serverEnvironment`.
    "nix": r"""
log "$@"
[ "$1 $2" = "eval --json" ] || exit 64
attr=${3#*#nixosConfigurations.}
h=${attr%%._module.specialArgs.hostSpec.serverEnvironment}
[ "$h" != "$attr" ] || exit 64
printf '%s' "$STUB_ENVS" | python3 -c '
import json, sys
envs = json.load(sys.stdin)
h = sys.argv[1]
if h not in envs:
    print("error: flake does not provide attribute", file=sys.stderr)
    sys.exit(1)
print(json.dumps(envs[h]))
' "$h"
""",
    "ssh": r"""
log "$@"
# skip options to the destination, then run the remote command locally
while [ $# -gt 0 ]; do
  case $1 in -o?* | -T) shift ;; -*) exit 65 ;; *) break ;; esac
done
shift
exec "$@"
""",
    "hostname": 'echo "${STUB_HOSTNAME:-hpp-1}"',
    "readlink": r"""
case $1 in
  /run/current-system) cat "$STUB_STATE/current" ;;
  /run/booted-system) echo "$STUB_OLD" ;;
  /nix/var/nix/profiles/system) echo "system-$(cat "$STUB_STATE/generation")-link" ;;
  *) exit 1 ;;
esac
""",
    "systemctl": r"""
case "$*" in
  is-system-running) state=$(cat "$STUB_STATE/system_state"); echo "$state"; [ "$state" = running ] ;;
  "list-units --state=failed --no-legend --plain") cat "$STUB_STATE/failed" ;;
  "is-active nixos-upgrade.service") echo "${STUB_UPGRADE:-inactive}"; [ "${STUB_UPGRADE:-inactive}" = active ] ;;
  "show nixos-upgrade.timer -p NextElapseUSecRealtime --value") echo "Mon 2026-11-23 04:40:00 UTC" ;;
  *) exit 1 ;;
esac
""",
}

# Stands in for scripts/activate-nixos.sh. Every invocation is logged; a switch
# changes the stub target's running system and generation.
HELPER = r"""
log "$@"
case " $* " in
  *" --dry-run "*)
    [ "${STUB_DRYRUN_RC:-0}" = 0 ] || { echo "activate-nixos: eval failed" >&2; exit "$STUB_DRYRUN_RC"; }
    echo "plan: host=hpp-1 action=switch closure=$STUB_NEW" ;;
  *" --preflight "*)
    [ "${STUB_PREFLIGHT_RC:-0}" = 0 ] || {
      echo "preflight: no usable SSH master for ipreston@hpp-1. Open it from an operator terminal using the same destination and SSH options." >&2
      exit "$STUB_PREFLIGHT_RC"; }
    echo "preflight: passed for hpp-1" >&2 ;;
  *" --action check "*)
    echo "preflight: passed for hpp-1" >&2
    [ "${STUB_CHECK_RC:-0}" = 0 ] || { echo "activate-nixos: refusing: closure is configured for host 'x'" >&2; exit "$STUB_CHECK_RC"; } ;;
  *" --action switch "*)
    echo "preflight: passed for hpp-1" >&2
    sleep "${STUB_SWITCH_SLEEP:-0}"
    [ "${STUB_SWITCH_RC:-0}" = 0 ] || { echo "activate-nixos: activation of hpp-1 on ipreston@hpp-1 failed (not retried)" >&2; exit "$STUB_SWITCH_RC"; }
    echo "$STUB_NEW" > "$STUB_STATE/current"
    echo $(($(cat "$STUB_STATE/generation") + 1)) > "$STUB_STATE/generation"
    touch "$STUB_STATE/switch-finished" ;;
  *) exit 64 ;;
esac
"""

EVIDENCE_KEYS = {
    "schema",
    "host",
    "target",
    "server_environment",
    "switch_requested",
    "run_dir",
    "started_at",
    "finished_at",
    "result",
    "failed_stage",
    "message",
    "source",
    "inputs",
    "expected_closure",
    "pre",
    "post",
    "generation_changed",
    "probes",
    "observe",
    "stages",
}
STAGE_NAMES = [
    "inputs",
    "preflight",
    "pre-state",
    "check",
    "switch",
    "post",
    "observe",
    "evidence",
]


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="validate-host-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts" / "_validate-host").mkdir(parents=True)
        (self.repo / "taskfiles").mkdir()
        shutil.copy(REPO / "scripts" / "validate-host.py", self.repo / "scripts")
        shutil.copy(
            REPO / "scripts" / "_validate-host" / "remote.sh",
            self.repo / "scripts" / "_validate-host",
        )
        # Task evaluates every included file's vars, including this one.
        shutil.copy(REPO / "scripts" / "secrets-dir.sh", self.repo / "scripts")
        shutil.copy(REPO / "Taskfile.yaml", self.repo)
        for f in (REPO / "taskfiles").glob("*.yaml"):
            shutil.copy(f, self.repo / "taskfiles")
        (self.repo / "scripts" / "activate-nixos.sh").write_text(
            SHEBANG + LOGGER + HELPER
        )
        lock = {
            "root": "root",
            "nodes": {
                "root": {"inputs": {"nix-secrets": "nix-secrets"}},
                "nix-secrets": {"locked": {"rev": SECRETS_REV}},
            },
            "version": 7,
        }
        (self.repo / "flake.lock").write_text(json.dumps(lock))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        for name, body in STUBS.items():
            p = self.stubs / name
            p.write_text(SHEBANG + LOGGER + body)
            p.chmod(0o755)
        self.state = self.tmp / "target"
        self.state.mkdir()
        (self.state / "current").write_text(OLD + "\n")
        (self.state / "generation").write_text("41\n")
        (self.state / "system_state").write_text("running\n")
        (self.state / "failed").write_text("")
        self.log = self.tmp / "stub.log"
        self.log.write_text("")
        self.xdg_state = self.tmp / "state"
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_ENV)
        env.update(
            PATH=f"{self.stubs}{os.pathsep}{env.get('PATH', '')}",
            HOME=str(self.home),
            XDG_STATE_HOME=str(self.xdg_state),
            STUB_LOG=str(self.log),
            STUB_STATE=str(self.state),
            STUB_ENVS=json.dumps(ENVS),
            STUB_OLD=OLD,
            STUB_NEW=NEW,
        )
        self.env = env
        subprocess.run(["git", *GIT_FLAGS, "init", "-q"], cwd=self.repo, env=env, check=True)  # fmt: skip
        subprocess.run(["git", *GIT_FLAGS, "add", "-A"], cwd=self.repo, env=env, check=True)  # fmt: skip
        subprocess.run(["git", *GIT_FLAGS, "commit", "-qm", "fixture"], cwd=self.repo, env=env, check=True)  # fmt: skip

    def drive(self, *argv, timeout=120, **env):
        return subprocess.run(
            [sys.executable, str(self.repo / "scripts" / "validate-host.py"), *argv],
            cwd=self.repo,
            env={**self.env, **{k: str(v) for k, v in env.items()}},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )

    def calls(self, tool=None):
        out = []
        for line in self.log.read_text().splitlines():
            name, args, sshopts = line.split("\t")
            if tool is None or name == tool:
                out.append((name, args, sshopts))
        return out

    def helper_calls(self):
        return [args for name, args, _ in self.calls("activate-nixos.sh")]

    def evidence(self, r):
        path = Path(r.stdout.strip().splitlines()[-1])
        self.assertTrue(path.is_file(), r.stderr)
        return path, json.loads(path.read_text())

    def statuses(self, ev):
        return {s["name"]: s["status"] for s in ev["stages"]}

    def run_dirs(self):
        base = self.xdg_state / "nixos-validate"
        return list(base.rglob("evidence.json")) if base.exists() else []


class Sequence(Harness):
    def test_check_only_runs_stages_in_order(self):
        r = self.drive("--host", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["result"], "passed")
        self.assertEqual([s["name"] for s in ev["stages"]], STAGE_NAMES)
        self.assertEqual(
            self.statuses(ev),
            {
                "inputs": "passed",
                "preflight": "passed",
                "pre-state": "passed",
                "check": "passed",
                "switch": "skipped",
                "post": "passed",
                "observe": "skipped",
                "evidence": "passed",
            },
        )
        # admission eval, then the helper's dry-run and preflight, and only
        # then any ssh; the check comes after the pre-change read.
        order = [
            (n, a.split()[-1] if n == "activate-nixos.sh" else "")
            for n, a, _ in self.calls()
        ]
        self.assertEqual(order[0], ("nix", ""))
        helper = [a for a in self.helper_calls()]
        self.assertEqual(len(helper), 3)
        self.assertTrue(helper[0].endswith("--dry-run"))
        self.assertTrue(helper[1].endswith("--preflight"))
        self.assertTrue(helper[2].endswith("--action check"))
        names = [n for n, _, _ in self.calls()]
        first_ssh = names.index("ssh")
        self.assertGreater(first_ssh, names.index("activate-nixos.sh") + 1)
        self.assertEqual(ev["post"]["current_system"], OLD)
        self.assertFalse(ev["generation_changed"])

    def test_switch_with_probes_and_observe_records_the_evidence(self):
        r = self.drive(
            "--host", "hpp-1", "--switch",
            "--probe", "true", "--probe", 'test "$(echo a b)" = "a b"',
            "--observe", "2s", "--interval", "1s",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        path, ev = self.evidence(r)
        self.assertEqual(ev["result"], "passed")
        self.assertEqual(set(self.statuses(ev).values()), {"passed"})
        switches = [a for a in self.helper_calls() if a.endswith("--action switch")]
        self.assertEqual(len(switches), 1)
        self.assertEqual(ev["expected_closure"], NEW)
        self.assertEqual(ev["pre"]["current_system"], OLD)
        self.assertEqual(ev["pre"]["generation"], 41)
        self.assertEqual(ev["post"]["current_system"], NEW)
        self.assertEqual(ev["post"]["generation"], 42)
        self.assertTrue(ev["generation_changed"])
        self.assertEqual([p["exit_code"] for p in ev["probes"]], [0, 0])
        self.assertGreaterEqual(ev["observe"]["iterations"], 2)
        self.assertTrue(ev["observe"]["ok"])
        # one log per stage that ran, all inside the run dir, outside the repo
        run_dir = path.parent
        self.assertEqual(Path(ev["run_dir"]), run_dir)
        self.assertNotIn(self.repo.resolve(), run_dir.resolve().parents)
        for s in ev["stages"]:
            self.assertTrue(Path(s["log"]).is_file(), s)
            self.assertEqual(Path(s["log"]).parent, run_dir)

    def test_evidence_record_shape_and_no_probe_output(self):
        r = self.drive("--host", "hpp-1", "--probe", "printf 's3cr3t-%s' probe-output")
        self.assertEqual(r.returncode, 0, r.stderr)
        path, ev = self.evidence(r)
        self.assertEqual(set(ev), EVIDENCE_KEYS)
        self.assertEqual(ev["schema"], "nixos-validate-host/1")
        self.assertEqual(ev["host"], "hpp-1")
        self.assertEqual(ev["target"], "ipreston@hpp-1")
        self.assertEqual(ev["server_environment"], "dev")
        self.assertEqual(ev["inputs"]["nix_secrets_locked_rev"], SECRETS_REV)
        self.assertFalse(ev["inputs"]["local_secrets"])
        self.assertRegex(ev["source"]["sha"], r"^[0-9a-f]{40}$")
        self.assertFalse(ev["source"]["dirty"])
        for key in ("current_system", "booted_system", "generation", "system_state", "failed_units", "upgrade_service", "upgrade_timer_next"):  # fmt: skip
            self.assertIn(key, ev["pre"])
        self.assertEqual(ev["pre"]["upgrade_timer_next"], "Mon 2026-11-23 04:40:00 UTC")
        for s in ev["stages"]:
            self.assertLessEqual({"name", "status", "log"}, set(s))
        text = path.read_text()
        self.assertNotIn("s3cr3t-probe-output", text)
        post_log = Path(next(s["log"] for s in ev["stages"] if s["name"] == "post"))
        self.assertIn("s3cr3t-probe-output", post_log.read_text())
        self.assertTrue(r.stdout.strip().endswith("evidence.json"))

    def test_home_paths_in_overrides_are_redacted(self):
        r = self.drive("--host", "hpp-1", "--override-input", "nix-secrets", f"path:{self.home}/src/nix-secrets")  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["inputs"]["override_inputs"], [{"name": "nix-secrets", "value": "path:~/src/nix-secrets"}])  # fmt: skip
        for args in self.helper_calls():
            self.assertIn(f"--override-input nix-secrets path:{self.home}/src/nix-secrets", args)  # fmt: skip


class Failures(Harness):
    def assert_stopped_at(self, r, stage, code=1):
        self.assertEqual(r.returncode, code, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], stage)
        st = self.statuses(ev)
        after = STAGE_NAMES[STAGE_NAMES.index(stage) + 1 : -1]
        for name in after:
            self.assertEqual(st[name], "not-run", (name, st))
        self.assertEqual(st["evidence"], "passed")
        return ev

    def test_failed_dry_run_stops_before_any_connection(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_DRYRUN_RC=1)
        ev = self.assert_stopped_at(r, "inputs")
        self.assertEqual(ev["message"], "activate-nixos: eval failed")
        self.assertEqual(self.calls("ssh"), [])
        self.assertEqual(len(self.helper_calls()), 1)

    def test_failed_preflight_reports_the_classified_message_and_stops(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_PREFLIGHT_RC=1)
        ev = self.assert_stopped_at(r, "preflight")
        self.assertTrue(ev["message"].startswith("preflight: no usable SSH master"))
        self.assertEqual(self.calls("ssh"), [])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))

    def test_wrong_host_stops_before_check(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_HOSTNAME="terra")
        ev = self.assert_stopped_at(r, "pre-state")
        self.assertIn("did not report hostname hpp-1", ev["message"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))

    def test_running_auto_upgrade_blocks_validation(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_UPGRADE="active")
        ev = self.assert_stopped_at(r, "pre-state")
        self.assertIn("nixos-upgrade.service is active", ev["message"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))

    def test_failed_check_prevents_the_switch(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_CHECK_RC=1)
        ev = self.assert_stopped_at(r, "check")
        self.assertIn("refusing", ev["message"])
        self.assertFalse(any(a.endswith("--action switch") for a in self.helper_calls()))  # fmt: skip

    def test_failed_switch_is_not_retried_or_rolled_back(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_SWITCH_RC=1)
        ev = self.assert_stopped_at(r, "switch")
        self.assertIn("not retried", ev["message"])
        switches = [a for a in self.helper_calls() if "--action switch" in a]
        self.assertEqual(len(switches), 1)
        # nothing after the failed switch touched the host
        names = [n for n, _, _ in self.calls()]
        self.assertEqual(names[-1], "activate-nixos.sh")

    def test_switch_past_its_deadline_is_left_running_and_unknown(self):
        r = self.drive("--host", "hpp-1", "--switch", "--switch-timeout", "1", STUB_SWITCH_SLEEP=3)  # fmt: skip
        ev = self.assert_stopped_at(r, "switch", code=3)
        self.assertEqual(ev["result"], "unknown")
        self.assertIn("left running", ev["message"])
        self.assertFalse((self.state / "switch-finished").exists())
        for _ in range(100):  # the activation was not signalled: it finishes
            if (self.state / "switch-finished").exists():
                break
            time.sleep(0.1)
        self.assertTrue((self.state / "switch-finished").exists())

    def test_running_system_changed_before_switch_is_refused(self):
        # check build "takes long" and the host moves meanwhile
        helper = self.repo / "scripts" / "activate-nixos.sh"
        helper.write_text(
            helper.read_text().replace(
                '*" --action check "*)',
                '*" --action check "*)\n    echo "/nix/store/x-other" > "$STUB_STATE/current"',
            )
        )
        r = self.drive("--host", "hpp-1", "--switch")
        ev = self.assert_stopped_at(r, "switch")
        self.assertIn("changed since pre-state", ev["message"])
        self.assertFalse(any(a.endswith("--action switch") for a in self.helper_calls()))  # fmt: skip

    def test_failed_probe_fails_post(self):
        r = self.drive("--host", "hpp-1", "--switch", "--probe", "exit 3", "--observe", "5s")  # fmt: skip
        ev = self.assert_stopped_at(r, "post")
        self.assertEqual(ev["probes"], [{"command": "exit 3", "exit_code": 3}])
        self.assertIn("probe 'exit 3' exited 3", ev["message"])

    def test_degraded_system_fails_post(self):
        (self.state / "system_state").write_text("degraded\n")
        (self.state / "failed").write_text("foo.service loaded failed failed Foo\n")
        r = self.drive("--host", "hpp-1", "--switch")
        ev = self.assert_stopped_at(r, "post")
        self.assertEqual(ev["post"]["failed_units"], ["foo.service"])
        self.assertIn("degraded", ev["message"])

    def test_observation_catches_a_later_regression(self):
        counter = self.state / "probe-count"
        probe = f'n=$(cat {counter} 2>/dev/null || echo 0); echo $((n + 1)) > {counter}; [ "$n" -lt 1 ]'  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch", "--probe", probe, "--observe", "3s", "--interval", "1s")  # fmt: skip
        ev = self.assert_stopped_at(r, "observe")
        self.assertEqual(ev["observe"]["iterations"], 1)
        self.assertFalse(ev["observe"]["ok"])
        self.assertIn("observation check 1", ev["message"])


class Admission(Harness):
    def assert_refused_offline(self, r):
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(self.calls("ssh"), [])
        self.assertEqual(self.helper_calls(), [])
        self.assertEqual(self.run_dirs(), [])
        self.assertFalse((self.xdg_state / "nixos-validate").exists())

    def test_non_dev_and_unknown_hosts_are_refused_before_any_ssh(self):
        for host, why in (
            ("amos1", 'serverEnvironment is "prod"'),
            ("terra", "serverEnvironment is null"),
            ("nosuch", "unknown host"),
        ):
            with self.subTest(host=host):
                self.log.write_text("")
                r = self.drive("--host", host, "--switch")
                self.assert_refused_offline(r)
                self.assertIn(why, r.stderr)

    def test_invalid_host_names_are_refused_before_any_eval(self):
        for host in ("HPP-1", "hpp-1;true", "-hpp", "../x", ""):
            with self.subTest(host=host):
                self.log.write_text("")
                r = self.drive("--host", host)
                self.assert_refused_offline(r)
                self.assertEqual(self.calls("nix"), [])

    def test_admission_eval_failure_fails_closed(self):
        r = self.drive("--host", "hpp-1", STUB_ENVS="not json")
        self.assert_refused_offline(r)

    def test_no_option_skips_helper_assertions(self):
        for extra in (
            ["--skip-preflight"],
            ["--dry-run"],
            ["--action", "switch"],
            ["--dest", "amos1"],
            ["--target-ssh-opt=-oControlPath=none"],
            ["--skip"],  # no abbreviations
            ["--host", "tests-server"],  # a second host
        ):
            with self.subTest(extra=extra):
                self.log.write_text("")
                r = self.drive("--host", "hpp-1", "--switch", *extra)
                self.assert_refused_offline(r)
                self.assertEqual(self.calls(), [])

    def test_environment_cannot_bypass_preflight_or_share_ssh_options(self):
        r = self.drive(
            "--host", "hpp-1", "--switch",
            SKIP_PREFLIGHT="true", NIX_SSHOPTS="-oControlPath=/tmp/other-host",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        helper = self.helper_calls()
        self.assertTrue(any(a.endswith("--preflight") for a in helper))
        for args in helper:
            self.assertNotIn("--skip-preflight", args)
            self.assertTrue(args.startswith("--host hpp-1 --dest hpp-1"), args)
        for name, args, sshopts in self.calls():
            self.assertEqual(sshopts, "NIX_SSHOPTS=[]", (name, args))
        for _, args, _ in self.calls("ssh"):
            argv = args.split()
            self.assertEqual(argv[-5:-2], ["bash", "-s", "--"])
            self.assertEqual(argv[-6], "ipreston@hpp-1")
            for opt in ("-oBatchMode=yes", "-oControlMaster=no", "-oRemoteCommand=none", "-T"):  # fmt: skip
                self.assertIn(opt, argv)

    def test_run_dir_inside_the_checkout_is_refused(self):
        r = self.drive("--host", "hpp-1", "--run-dir", str(self.repo / "logs"))
        self.assert_refused_offline(r)
        self.assertFalse((self.repo / "logs").exists())

    def test_bad_durations_are_usage_errors(self):
        for extra in (["--observe", "3x"], ["--observe", "5h"], ["--interval", "0"]):
            with self.subTest(extra=extra):
                self.log.write_text("")
                r = self.drive("--host", "hpp-1", *extra)
                self.assert_refused_offline(r)


class TaskWrapper(Harness):
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
            timeout=120,
        )

    def test_arguments_pass_through_one_quoted_word_each(self):
        probe = """test "$(printf '%s' 'it'"'"'s; $HOME')" = "it's; \\$HOME" """
        r = self.task("validate:hpp-1", "--", "--switch", "--probe", probe)
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["result"], "passed")
        self.assertEqual(ev["probes"], [{"command": probe, "exit_code": 0}])
        self.assertTrue(any(a.endswith("--action switch") for a in self.helper_calls()))  # fmt: skip

    def test_default_is_check_only_and_the_environment_cannot_switch(self):
        r = self.task("validate:hpp-1", SWITCH="true", CLI_ARGS="--switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any("--action switch" in a for a in self.helper_calls()))

    def test_task_refuses_a_prod_host_before_any_ssh(self):
        r = self.task("validate:amos1", "--", "--switch")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('serverEnvironment is "prod"', r.stderr)
        self.assertEqual(self.calls("ssh"), [])
        self.assertEqual(self.helper_calls(), [])

    def test_task_cannot_redirect_the_host(self):
        r = self.task("validate:hpp-1", "--", "--host", "tests-server")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--host may be given only once", r.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
