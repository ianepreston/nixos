#!/usr/bin/env python3
"""Offline tests for scripts/validate-host.py (#1063, #1071).

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
import hashlib
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
OTHER = f"/nix/store/{HASH_OLD[::-1]}-nixos-system-hpp-1-26.05.20261110.ccccccc"
SECRETS_REV = "1" * 40
# hostSpec admission fields per host, as `nix eval --apply ADMIT_APPLY` returns
# them. `rogue` is marked but not dev; `legacy` predates the marker.
SPECS = {
    "hpp-1": {"serverEnvironment": "dev", "validationTarget": True},
    "tests-server": {"serverEnvironment": "dev", "validationTarget": False},
    "amos1": {"serverEnvironment": "prod", "validationTarget": False},
    "terra": {"serverEnvironment": None, "validationTarget": False},
    "rogue": {"serverEnvironment": "prod", "validationTarget": True},
    "legacy": {"serverEnvironment": "dev", "validationTarget": None},
    "stringly": {"serverEnvironment": "dev", "validationTarget": "true"},
}
INVOCATION = "0123456789abcdef0123456789abcdef"


def probe_id(command):
    return hashlib.sha256(command.encode()).hexdigest()[:12]


def fingerprint(value):
    return hashlib.sha256(value.encode()).hexdigest()[:12]


LOGGER = r"""
log() { printf '%s\t%s\tNIX_SSHOPTS=[%s]\n' "$(basename "$0")" "$*" "${NIX_SSHOPTS-}" >> "$STUB_LOG"; }
"""

STUBS = {
    # Only `nix eval --json <flake>#nixosConfigurations.<h>._module.specialArgs.hostSpec --apply <expr>`.
    "nix": r"""
log "$@"
[ "$1 $2 $4 $#" = "eval --json --apply 5" ] || exit 64
case $5 in *validationTarget*serverEnvironment* | *serverEnvironment*validationTarget*) ;; *) exit 64 ;; esac
attr=${3#*#nixosConfigurations.}
h=${attr%%._module.specialArgs.hostSpec}
[ "$h" != "$attr" ] || exit 64
printf '%s' "$STUB_SPECS" | python3 -c '
import json, sys
specs = json.load(sys.stdin)
h = sys.argv[1]
if h not in specs:
    print("error: flake does not provide attribute", file=sys.stderr)
    sys.exit(1)
print(json.dumps(specs[h]))
' "$h"
""",
    "ssh": r"""
log "$@"
# skip options to the destination, then run the remote command locally
while [ $# -gt 0 ]; do
  case $1 in -o?* | -T) shift ;; -*) exit 65 ;; *) break ;; esac
done
shift
script=$(cat; echo x)
script=${script%x}
case $script in
  *"probe <<'"*) [ -z "${STUB_SSH_DROP_PROBE:-}" ] || exit 255 ;;
esac
# Optional lines spliced into the output around the end marker (state reads
# only), standing in for a remote that sends something remote.sh never would.
out=$STUB_STATE/ssh-out.$$
printf '%s' "$script" | "$@" > "$out"
rc=$?
while IFS= read -r line || [ -n "$line" ]; do
  case $line in VALIDATE-END\ *) [ ! -f "$STUB_STATE/inject-before-end" ] || cat "$STUB_STATE/inject-before-end" ;; esac
  printf '%s\n' "$line"
  case $line in VALIDATE-END\ *) [ ! -f "$STUB_STATE/inject-after-end" ] || cat "$STUB_STATE/inject-after-end" ;; esac
done < "$out"
rm -f "$out"
exit "${STUB_SSH_EXIT:-$rc}"
""",
    "hostname": 'echo "${STUB_HOSTNAME:-hpp-1}"',
    "readlink": r"""
[ "${STUB_READLINK_FAIL:-}" != "$1" ] || exit 1
case $1 in
  /run/current-system) cat "$STUB_STATE/current" ;;
  /run/booted-system) echo "$STUB_OLD" ;;
  /nix/var/nix/profiles/system) echo "${STUB_PROFILE:-system-$(cat "$STUB_STATE/generation")-link}" ;;
  *) exit 1 ;;
esac
""",
    "systemctl": r"""
case "$*" in
  is-system-running) state=$(cat "$STUB_STATE/system_state"); echo "$state"; [ "$state" = running ] ;;
  "list-units --state=failed --no-legend --plain") [ -z "${STUB_LIST_UNITS_FAIL:-}" ] || exit 1; cat "$STUB_STATE/failed" ;;
  "show -p InvocationID -p StateChangeTimestampMonotonic -- "*)
    [ -z "${STUB_SHOW_FAIL:-}" ] || exit 1
    unit=${!#}
    if [ -f "$STUB_STATE/mark-$unit" ]; then cat "$STUB_STATE/mark-$unit"
    else printf 'InvocationID=%s\nStateChangeTimestampMonotonic=1000\n' "$STUB_INVOCATION"; fi ;;
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
if [ -n "${STUB_REJECT_OVERRIDE:-}" ]; then
  # like activate-nixos.sh safe(): the whole NAME=VALUE is echoed verbatim
  prev2="" prev1="" name="" value=""
  for a in "$@"; do
    if [ "$prev2" = --override-input ]; then name=$prev1 value=$a; fi
    prev2=$prev1 prev1=$a
  done
  case $STUB_REJECT_OVERRIDE:" $* " in
    dry-run:*" --dry-run "*)
      echo "activate-nixos: unsafe or empty override: '$name=$value'" >&2; exit 1 ;;
    preflight-path:*" --preflight "*)
      path=${value#*://*/}; echo "preflight: cannot read /${path%%\?*} on the build machine" >&2; exit 1 ;;
  esac
fi
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
    "validation_target",
    "switch_requested",
    "require_clean",
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
    "failed_units",
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
            STUB_SPECS=json.dumps(SPECS),
            STUB_INVOCATION=INVOCATION,
            STUB_OLD=OLD,
            STUB_NEW=NEW,
            STUB_OTHER=OTHER,
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
        obs = ev["observe"]
        self.assertGreaterEqual(obs["iterations"], 2)
        self.assertTrue(obs["ok"])
        self.assertIn(obs["clock"], ("CLOCK_BOOTTIME", "CLOCK_MONOTONIC_RAW", "monotonic"))  # fmt: skip
        self.assertIs(obs["suspend_aware"], obs["clock"] != "monotonic")
        self.assertLessEqual(obs["max_gap_s"], 2)
        self.assertLess(obs["max_late_s"], 1)
        self.assertEqual(obs["slow_checks"], 0)
        self.assertLessEqual(obs["started_at"], obs["finished_at"])
        observe_stage = next(s for s in ev["stages"] if s["name"] == "observe")
        self.assertEqual(
            observe_stage["summary"],
            f"{obs['iterations']} check(s) over {obs['elapsed_s']}s passed (interval 1s, largest gap {round(obs['max_gap_s'])}s)",
        )
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
        self.assertEqual(ev["schema"], "nixos-validate-host/3")
        self.assertEqual(ev["host"], "hpp-1")
        self.assertEqual(ev["target"], "ipreston@hpp-1")
        self.assertEqual(ev["server_environment"], "dev")
        self.assertIs(ev["validation_target"], True)
        self.assertIs(ev["require_clean"], False)
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
        value = f"path:{self.home}/src/nix-secrets"
        self.assertEqual(ev["inputs"]["override_inputs"], [{"name": "nix-secrets", "value": "path:~/src/nix-secrets", "fingerprint": fingerprint(value)}])  # fmt: skip
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
                '*" --action check "*)\n    echo "$STUB_OTHER" > "$STUB_STATE/current"',
            )
        )
        r = self.drive("--host", "hpp-1", "--switch")
        ev = self.assert_stopped_at(r, "switch")
        self.assertIn("changed since pre-state", ev["message"])
        self.assertFalse(any(a.endswith("--action switch") for a in self.helper_calls()))  # fmt: skip

    def test_failed_probe_fails_post(self):
        r = self.drive("--host", "hpp-1", "--switch", "--probe", "exit 3", "--observe", "5s")  # fmt: skip
        ev = self.assert_stopped_at(r, "post")
        self.assertEqual(
            ev["probes"], [{"index": 1, "id": probe_id("exit 3"), "exit_code": 3}]
        )
        self.assertEqual(ev["message"], f"probe #1 (id {probe_id('exit 3')}) exited 3")

    def test_degraded_system_fails_post(self):
        # foo.service fails during the switch: a new failure
        helper = self.repo / "scripts" / "activate-nixos.sh"
        helper.write_text(
            helper.read_text().replace(
                'touch "$STUB_STATE/switch-finished"',
                'echo degraded > "$STUB_STATE/system_state"; echo "foo.service loaded failed failed Foo" > "$STUB_STATE/failed"; touch "$STUB_STATE/switch-finished"',
            )
        )
        r = self.drive("--host", "hpp-1", "--switch")
        ev = self.assert_stopped_at(r, "post")
        self.assertEqual(ev["post"]["failed_units"], ["foo.service"])
        self.assertEqual(ev["post"]["system_state"], "degraded")
        self.assertIn(
            "1 new failed unit(s) since pre-state: foo.service", ev["message"]
        )

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

    def test_unmarked_non_dev_and_unknown_hosts_are_refused_before_any_ssh(self):
        for host, why in (
            # dev, but not a real ssh target: no marker (#1071)
            ("tests-server", "validationTarget is false"),
            ("amos1", "validationTarget is false"),
            ("terra", "validationTarget is false"),
            # the marker alone is not enough
            ("rogue", 'serverEnvironment is "prod"'),
            # a missing or non-boolean marker refuses like false
            ("legacy", "validationTarget is null"),
            ("stringly", 'validationTarget is "true"'),
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
        for specs in ("not json", json.dumps({"hpp-1": "dev"}), json.dumps({"hpp-1": True})):  # fmt: skip
            with self.subTest(specs=specs):
                self.log.write_text("")
                r = self.drive("--host", "hpp-1", STUB_SPECS=specs)
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
        self.assertEqual(
            ev["probes"], [{"index": 1, "id": probe_id(probe), "exit_code": 0}]
        )
        self.assertTrue(any(a.endswith("--action switch") for a in self.helper_calls()))  # fmt: skip

    def test_default_is_check_only_and_the_environment_cannot_switch(self):
        r = self.task("validate:hpp-1", SWITCH="true", CLI_ARGS="--switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any("--action switch" in a for a in self.helper_calls()))

    def test_task_refuses_unmarked_hosts_before_any_ssh(self):
        for host in ("amos1", "tests-server"):
            with self.subTest(host=host):
                self.log.write_text("")
                r = self.task(f"validate:{host}", "--", "--switch")
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("validationTarget is false", r.stderr)
                self.assertEqual(self.calls("ssh"), [])
                self.assertEqual(self.helper_calls(), [])

    def test_exit_code_flag_keeps_the_driver_status(self):
        # Documented in host-access.md: Task alone reports 201.
        self.assertEqual(self.task("validate:amos1").returncode, 201)
        self.assertEqual(self.task("--exit-code", "validate:amos1").returncode, 2)
        r = self.task("-x", "validate:hpp-1", "--", "--switch", "--switch-timeout", "1", STUB_SWITCH_SLEEP=3)  # fmt: skip
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_task_cannot_redirect_the_host(self):
        r = self.task("validate:hpp-1", "--", "--host", "tests-server")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--host may be given only once", r.stderr)
        self.assertEqual(self.calls(), [])


class Baseline(Harness):
    """#1071: failed units that predate the run are tolerated (and reported)
    by default; new or re-failed units fail; --require-clean fails on any."""

    UNIT = "stale.service loaded failed failed Stale\n"

    def stale_baseline(self):
        (self.state / "system_state").write_text("degraded\n")
        (self.state / "failed").write_text(self.UNIT)

    def on_switch(self, shell):
        helper = self.repo / "scripts" / "activate-nixos.sh"
        helper.write_text(
            helper.read_text().replace(
                'touch "$STUB_STATE/switch-finished"',
                f'{shell}; touch "$STUB_STATE/switch-finished"',
            )
        )

    def test_pre_existing_failure_is_tolerated_and_reported(self):
        self.stale_baseline()
        r = self.drive("--host", "hpp-1", "--switch", "--probe", "true", "--observe", "2s", "--interval", "1s")  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["result"], "passed")
        self.assertEqual(ev["pre"]["failed_units"], ["stale.service"])
        self.assertEqual(ev["pre"]["failed_unit_marks"], {"stale.service": f"{INVOCATION} 1000"})  # fmt: skip
        self.assertEqual(
            ev["failed_units"],
            {
                "baseline": ["stale.service"],
                "new": [],
                "changed": [],
                "tolerated": ["stale.service"],
                "cleared": [],
                "stage": "observe",
            },
        )
        self.assertTrue(ev["observe"]["ok"])
        post = next(s for s in ev["stages"] if s["name"] == "post")
        self.assertIn("degraded with 1 pre-existing failed unit(s) tolerated (stale.service)", post["summary"])  # fmt: skip
        self.assertIn("WARNING: 1 failed unit(s) predate this run and were tolerated: stale.service", r.stderr)  # fmt: skip

    def test_new_failure_beside_a_pre_existing_one_fails(self):
        self.stale_baseline()
        self.on_switch('echo "new.service loaded failed failed New" >> "$STUB_STATE/failed"')  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertEqual(ev["message"], "1 new failed unit(s) since pre-state: new.service")  # fmt: skip
        self.assertEqual(ev["failed_units"]["new"], ["new.service"])
        self.assertEqual(ev["failed_units"]["tolerated"], ["stale.service"])

    def test_new_failure_on_a_clean_host_fails(self):
        self.on_switch('echo degraded > "$STUB_STATE/system_state"; echo "new.service loaded failed failed New" > "$STUB_STATE/failed"')  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertIn("1 new failed unit(s) since pre-state: new.service", ev["message"])  # fmt: skip

    def test_pre_existing_unit_that_failed_again_fails(self):
        self.stale_baseline()
        self.on_switch(
            f'printf "InvocationID={INVOCATION[::-1]}\\nStateChangeTimestampMonotonic=2000\\n" > "$STUB_STATE/mark-stale.service"'
        )
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertEqual(
            ev["message"],
            "1 pre-existing failed unit(s) changed state since pre-state: stale.service",
        )
        self.assertEqual(ev["failed_units"]["changed"], ["stale.service"])
        self.assertEqual(ev["failed_units"]["tolerated"], [])

    def test_unit_failing_again_during_observation_fails(self):
        self.stale_baseline()
        counter = self.state / "probe-count"
        # the second probe run re-fails stale.service
        probe = (
            f"n=$(cat {counter} 2>/dev/null || echo 0); echo $((n + 1)) > {counter}; "
            f'[ "$n" -lt 1 ] || printf "InvocationID={"f" * 32}\\nStateChangeTimestampMonotonic=3000\\n" > {self.state}/mark-stale.service'
        )
        r = self.drive("--host", "hpp-1", "--probe", probe, "--observe", "3s", "--interval", "1s")  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "observe")
        self.assertIn("changed state since pre-state: stale.service", ev["message"])
        self.assertEqual(ev["observe"]["last"]["changed_failed_units"], ["stale.service"])  # fmt: skip

    LEAK = "someone" + "@" + "example.invalid"

    def assert_bad_baseline_stops_before_check(self, mark_text):
        """A failed unit whose mark is empty or malformed stops pre-state:
        nothing is checked or switched, even if the unit later disappears,
        and no mark text reaches the evidence."""
        self.stale_baseline()
        (self.state / "mark-stale.service").write_text(mark_text)
        # were the run to go on, the unit would vanish during the switch
        self.on_switch('echo running > "$STUB_STATE/system_state"; : > "$STUB_STATE/failed"')  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        path, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "pre-state")
        self.assertEqual(ev["result"], "failed")
        self.assertIn("required read 'failed_unit_mark' failed", ev["message"])
        self.assertIsNone(ev["pre"])
        self.assertIsNone(ev["failed_units"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))
        self.assertNotIn(self.LEAK, path.read_text())
        self.assertNotIn(self.LEAK, r.stderr)

    def test_empty_mark_stops_pre_state(self):
        for text in ("", "InvocationID=\nStateChangeTimestampMonotonic=\n"):
            with self.subTest(text=text):
                self.log.write_text("")
                self.assert_bad_baseline_stops_before_check(text)

    def test_malformed_mark_stops_pre_state(self):
        for text in (
            "Other=1\n",
            f"InvocationID={INVOCATION}\nStateChangeTimestampMonotonic=0\n",
            f"InvocationID={INVOCATION}\nStateChangeTimestampMonotonic=12x\n",
            f"InvocationID={INVOCATION.upper()}\nStateChangeTimestampMonotonic=5\n",
            f"InvocationID={INVOCATION[:-1]}\nStateChangeTimestampMonotonic=5\n",
            "InvocationID=-\nStateChangeTimestampMonotonic=5\n",
        ):
            with self.subTest(text=text):
                self.log.write_text("")
                self.assert_bad_baseline_stops_before_check(text)

    def test_arbitrary_text_in_a_mark_is_rejected_and_never_recorded(self):
        for text in (
            f"InvocationID={self.LEAK}\nStateChangeTimestampMonotonic=5\n",
            f"InvocationID={INVOCATION}\nStateChangeTimestampMonotonic=5 {self.LEAK}\n",
        ):
            with self.subTest(text=text):
                self.log.write_text("")
                self.assert_bad_baseline_stops_before_check(text)

    def parse(self, lines, after=()):
        """read_state() on canned remote output (the parser's own checks,
        independent of remote.sh's)."""
        import importlib.util
        import types

        spec = importlib.util.spec_from_file_location("vh", REPO / "scripts" / "validate-host.py")  # fmt: skip
        vh = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vh)
        nonce = "n" * 8
        base = [
            "hostname=hpp-1",
            f"current_system={OLD}",
            f"booted_system={OLD}",
            "system_profile=system-41-link",
            "system_state=degraded",
            "upgrade_service=inactive",
            "upgrade_timer_next=",
        ]
        v = types.SimpleNamespace(
            host="hpp-1",
            target="ipreston@hpp-1",
            closure_re=vh.re.compile(vh.CLOSURE_RE % "hpp-1"),
            remote=lambda *_, **__: (
                0,
                base + lines + [f"VALIDATE-END {nonce}", *after],
                nonce,
            ),
        )
        return vh, lambda: vh.Validation.read_state(v, "pre-state")

    def test_parser_rejects_malformed_missing_and_stray_marks(self):
        good = f"failed_unit_mark=stale.service {INVOCATION} 5"
        vh, read = self.parse(["failed_unit=stale.service", good])
        self.assertEqual(read()["failed_unit_marks"], {"stale.service": f"{INVOCATION} 5"})  # fmt: skip
        for lines, why in (
            (["failed_unit=stale.service", f"failed_unit_mark=stale.service {self.LEAK} 5"], "malformed"),
            (["failed_unit=stale.service", "failed_unit_mark=stale.service - -"], "malformed"),
            (["failed_unit=stale.service"], "incomplete"),
            ([good], "incomplete"),
            (["failed_unit=stale.service", good, "failed_unit=other.service"], "incomplete"),
        ):  # fmt: skip
            with self.subTest(lines=lines):
                mod, read = self.parse(lines)
                with self.assertRaises(mod.StageFailed) as cm:
                    read()
                self.assertIn(why, cm.exception.summary)
                self.assertNotIn(self.LEAK, cm.exception.summary)

    def test_failing_mark_read_fails_the_stage(self):
        self.stale_baseline()
        r = self.drive("--host", "hpp-1", "--switch", STUB_SHOW_FAIL=1)
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "pre-state")
        self.assertIn("required read 'failed_unit_mark' failed", ev["message"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))

    def test_cleared_failure_is_recorded(self):
        self.stale_baseline()
        self.on_switch('echo running > "$STUB_STATE/system_state"; : > "$STUB_STATE/failed"')  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_units"]["cleared"], ["stale.service"])
        self.assertEqual(ev["failed_units"]["tolerated"], [])

    def test_degraded_without_failed_units_still_fails(self):
        self.on_switch('echo degraded > "$STUB_STATE/system_state"')
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["message"], "system state is 'degraded', not 'running'")

    def test_require_clean_fails_on_a_pre_existing_failure_before_check(self):
        self.stale_baseline()
        r = self.drive("--host", "hpp-1", "--switch", "--require-clean")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertIs(ev["require_clean"], True)
        self.assertEqual(ev["failed_stage"], "pre-state")
        self.assertIn("--require-clean", ev["message"])
        self.assertIn("1 failed unit(s) before the change: stale.service", ev["message"])  # fmt: skip
        self.assertEqual(ev["failed_units"]["baseline"], ["stale.service"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))

    def test_require_clean_fails_on_a_new_failure(self):
        self.on_switch('echo degraded > "$STUB_STATE/system_state"; echo "new.service loaded failed failed New" > "$STUB_STATE/failed"')  # fmt: skip
        r = self.drive("--host", "hpp-1", "--switch", "--require-clean")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertIn("1 failed unit(s) (--require-clean): new.service", ev["message"])  # fmt: skip

    def test_require_clean_passes_on_a_clean_host(self):
        r = self.drive("--host", "hpp-1", "--switch", "--require-clean")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_task_passes_require_clean_through(self):
        task = shutil.which("task")
        if task is None:
            self.skipTest("go-task not available")
        self.stale_baseline()
        r = subprocess.run(
            [task, "--silent", "-x", "validate:hpp-1", "--", "--require-clean"],
            cwd=self.repo, env=self.env, capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=120,
        )  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "pre-state")

    # #1071 review 2: a snapshot is accepted only if it is unambiguous;
    # systemd's explicit empty InvocationID is a valid mark; a rejected mark
    # payload never reaches any file in the run dir.

    def test_remote_rejects_repeated_missing_or_unexpected_properties(self):
        ok_ts = "StateChangeTimestampMonotonic=5\n"
        for text in (
            # an earlier malformed value cannot hide behind a later valid one
            f"InvocationID={self.LEAK}\nInvocationID={INVOCATION}\n{ok_ts}",
            f"InvocationID={INVOCATION}\nInvocationID={INVOCATION}\n{ok_ts}",
            f"InvocationID={INVOCATION}\nStateChangeTimestampMonotonic=x\n{ok_ts}",
            f"InvocationID={INVOCATION}\n{ok_ts}{ok_ts}",
            f"InvocationID={INVOCATION}\n",
            ok_ts,
            f"InvocationID={INVOCATION}\n{ok_ts}Other=1\n",
            f"InvocationID={INVOCATION}\n\n{ok_ts}",
        ):
            with self.subTest(text=text):
                self.log.write_text("")
                self.assert_bad_baseline_stops_before_check(text)

    def test_empty_invocation_id_with_a_timestamp_is_a_valid_mark(self):
        self.stale_baseline()
        (self.state / "mark-stale.service").write_text(
            "InvocationID=\nStateChangeTimestampMonotonic=1000\n"
        )
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["pre"]["failed_unit_marks"], {"stale.service": "- 1000"})
        self.assertEqual(ev["failed_units"]["tolerated"], ["stale.service"])

    def test_empty_invocation_id_still_detects_a_later_failure(self):
        self.stale_baseline()
        (self.state / "mark-stale.service").write_text(
            "InvocationID=\nStateChangeTimestampMonotonic=1000\n"
        )
        self.on_switch(
            'printf "InvocationID=\\nStateChangeTimestampMonotonic=2000\\n" > "$STUB_STATE/mark-stale.service"'
        )
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertEqual(ev["failed_units"]["changed"], ["stale.service"])

    def test_parser_rejects_every_ambiguous_snapshot(self):
        unit = "failed_unit=stale.service"
        good = f"failed_unit_mark=stale.service {INVOCATION} 5"
        other = f"failed_unit_mark=stale.service {INVOCATION} 6"
        for lines, after, why in (
            ([unit, unit, good], (), "repeats a unit"),
            ([unit, good, good], (), "repeats a unit"),
            ([unit, good, other], (), "repeats a unit"),
            (["failed_unit=", good], (), "malformed"),
            ([unit, good, f"failed_unit_mark= {INVOCATION} 5"], (), "malformed"),
            ([unit, f"failed_unit_mark=stale.service  {INVOCATION} 5"], (), "malformed"),
            ([unit, good, "system_state=running"], (), "system_state read from hpp-1 is repeated"),
            ([unit, good, "hostname=hpp-1"], (), "hostname read from hpp-1 is repeated"),
            # a later (old) mark must not overwrite the snapshot's own
            ([unit, other], [good], "output after its end marker"),
            ([unit, good], ["failed_unit=new.service"], "output after its end marker"),
            ([unit, good], ["VALIDATE-END " + "n" * 8], "did not complete"),
        ):  # fmt: skip
            with self.subTest(lines=lines, after=after):
                mod, read = self.parse(lines, after)
                with self.assertRaises(mod.StageFailed) as cm:
                    read()
                self.assertIn(why, cm.exception.summary)
        # a blank trailing line (ssh's own newline) is not output
        mod, read = self.parse([unit, good], [""])
        self.assertEqual(read()["failed_units"], ["stale.service"])

    def test_old_mark_after_the_end_marker_cannot_mask_a_change(self):
        self.stale_baseline()
        self.on_switch(
            'printf "InvocationID=%s\\nStateChangeTimestampMonotonic=2000\\n" "$STUB_INVOCATION" > "$STUB_STATE/mark-stale.service"; '
            'echo "failed_unit_mark=stale.service $STUB_INVOCATION 1000" > "$STUB_STATE/inject-after-end"'
        )
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertIn("output after its end marker", ev["message"])

    def run_dir_text(self, ev):
        run_dir = Path(ev["run_dir"])
        return "".join(
            f.read_text(errors="replace") for f in run_dir.rglob("*") if f.is_file()
        )

    def test_rejected_mark_payload_is_in_no_run_dir_file(self):
        for inject in (
            f"failed_unit_mark=stale.service {self.LEAK} 5\n",
            f"failed_unit_mark={self.LEAK} {INVOCATION} 5\n",
            f"failed_unit={self.LEAK}\n",
        ):
            with self.subTest(inject=inject):
                self.log.write_text("")
                self.stale_baseline()
                (self.state / "inject-before-end").write_text(inject)
                r = self.drive("--host", "hpp-1", "--switch")
                self.assertEqual(r.returncode, 1, r.stderr)
                _, ev = self.evidence(r)
                self.assertEqual(ev["failed_stage"], "pre-state")
                self.assertFalse(any("--action" in a for a in self.helper_calls()))
                text = self.run_dir_text(ev)
                self.assertNotIn(self.LEAK, text)
                self.assertNotIn(self.LEAK, r.stderr)
                self.assertIn("withheld", text)
                # normal unit names and valid marks are still logged
                self.assertIn(f"failed_unit_mark=stale.service {INVOCATION} 1000", text)

    def test_valid_state_read_is_logged_unchanged(self):
        self.stale_baseline()
        r = self.drive("--host", "hpp-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        log = Path(next(s["log"] for s in ev["stages"] if s["name"] == "pre-state"))
        text = log.read_text()
        self.assertIn("failed_unit=stale.service\n", text)
        self.assertIn(f"failed_unit_mark=stale.service {INVOCATION} 1000\n", text)
        self.assertNotIn("withheld", text)


class HostReads(Harness):
    """#1: a failed or empty required read fails the stage; it is never
    recorded as an empty or zero value."""

    def assert_read_failed(self, r, stage, key=None):
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], stage)
        if key:
            self.assertIn(f"required read '{key}' failed", ev["message"])
        self.assertFalse(any("--action" in a for a in self.helper_calls()))
        return ev

    def test_failing_list_units_is_not_zero_failed_units(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_LIST_UNITS_FAIL=1)
        ev = self.assert_read_failed(r, "pre-state", "failed_units")
        self.assertIsNone(ev["pre"])

    def test_failing_readlinks_fail_the_read(self):
        for path, key in (
            ("/run/current-system", "current_system"),
            ("/run/booted-system", "booted_system"),
            ("/nix/var/nix/profiles/system", "system_profile"),
        ):
            with self.subTest(path=path):
                self.log.write_text("")
                r = self.drive("--host", "hpp-1", "--switch", STUB_READLINK_FAIL=path)
                self.assert_read_failed(r, "pre-state", key)

    def test_unparsable_generation_never_becomes_a_baseline(self):
        r = self.drive("--host", "hpp-1", "--switch", STUB_PROFILE="system-link")
        ev = self.assert_read_failed(r, "pre-state")
        self.assertIn("generation", ev["message"])

    def test_malformed_closure_never_becomes_a_baseline(self):
        (self.state / "current").write_text("/nix/store/not-a-system\n")
        r = self.drive("--host", "hpp-1", "--switch")
        ev = self.assert_read_failed(r, "pre-state")
        self.assertIn("current_system", ev["message"])

    def test_failed_read_in_the_switch_guard_stops_before_switching(self):
        helper = self.repo / "scripts" / "activate-nixos.sh"
        helper.write_text(
            helper.read_text().replace(
                '*" --action check "*)',
                '*" --action check "*)\n    echo "system-link" > "$STUB_STATE/generation"',
            )
        )
        r = self.drive("--host", "hpp-1", "--switch")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "switch")
        self.assertFalse(
            any(a.endswith("--action switch") for a in self.helper_calls())
        )

    def test_inactive_upgrade_service_and_missing_timer_are_expected_states(self):
        r = self.drive("--host", "hpp-1", STUB_UPGRADE="inactive")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["pre"]["upgrade_service"], "inactive")


class Transport(Harness):
    """#2: ssh must succeed AND report the marker; the first transport or
    probe failure ends the stage with no further connection."""

    def probe_connections(self):
        return [a for _, a, _ in self.calls("ssh")]

    def test_ssh_failure_with_a_marker_still_fails(self):
        r = self.drive("--host", "hpp-1", STUB_SSH_EXIT=255)
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "pre-state")
        self.assertIn("ssh to ipreston@hpp-1 failed (exit 255)", ev["message"])
        self.assertEqual(len(self.calls("ssh")), 1)

    def test_dropped_probe_connection_stops_probing(self):
        r = self.drive(
            "--host", "hpp-1", "--probe", "true", "--probe", "true", "--probe", "true",
            STUB_SSH_DROP_PROBE=1,
        )  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertIn("ssh to ipreston@hpp-1 failed (exit 255)", ev["message"])
        # pre-state + post state read + the one dropped probe; nothing after
        self.assertEqual(len(self.calls("ssh")), 3)
        self.assertEqual(self.calls()[-1][0], "ssh")

    def test_failing_probe_stops_further_probes_and_connections(self):
        r = self.drive("--host", "hpp-1", "--switch", "--probe", "exit 4", "--probe", "true", "--observe", "5s")  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertEqual([p["exit_code"] for p in ev["probes"]], [4])
        # pre-state, switch guard, post state, one probe
        self.assertEqual(len(self.calls("ssh")), 4)

    def test_probes_run_under_pipefail(self):
        r = self.drive("--host", "hpp-1", "--probe", "false | cat")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["probes"][0]["exit_code"], 1)


class Redaction(Harness):
    """#3: no probe text and no credential-like material in the evidence."""

    def test_probe_text_never_reaches_the_evidence(self):
        token = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"
        probe = (
            f"curl -fsS -H 'Authorization: Bearer {token}' https://x.invalid/ | exit 7"
        )
        r = self.drive("--host", "hpp-1", "--probe", probe)
        self.assertEqual(r.returncode, 1, r.stderr)
        path, ev = self.evidence(r)
        text = path.read_text()
        self.assertNotIn(token, text)
        self.assertNotIn("Authorization", text)
        self.assertNotIn("curl", text)
        self.assertEqual(
            ev["probes"], [{"index": 1, "id": probe_id(probe), "exit_code": 7}]
        )
        self.assertNotIn("curl", r.stderr)

    def test_override_values_lose_userinfo_queries_and_tokens(self):
        token = "Zx9" + "Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk"
        overrides = {
            # not a recognised form: origin only, plus the safe ref
            "a": ("git+https://alice:hunter2@example.invalid/r.git?ref=main&token=abc", {"value": "git+https://example.invalid", "ref": "main"}),
            # recognised form, too short to be a revision: rev dropped
            "b": ("github:o/r?rev=0123", {"value": "github:o/r"}),
            "c": (f"path:/srv/{token}/x", {"value": "path:/srv/<redacted>/x"}),
            "d": (f"path:{self.home}/src/nix-secrets", {"value": "path:~/src/nix-secrets"}),
        }  # fmt: skip
        argv = ["--host", "hpp-1"]
        for name, (value, _) in overrides.items():
            argv += ["--override-input", name, value]
        r = self.drive(*argv)
        self.assertEqual(r.returncode, 0, r.stderr)
        path, ev = self.evidence(r)
        self.assertEqual(
            ev["inputs"]["override_inputs"],
            [
                {**want, "name": n, "fingerprint": fingerprint(value)}
                for n, (value, want) in overrides.items()
            ],
        )
        text = path.read_text()
        for leak in (
            "hunter2",
            "alice",
            "token=abc",
            "rev=0123",
            token,
            str(self.home),
        ):
            self.assertNotIn(leak, text)

    def test_failure_messages_are_scrubbed(self):
        token = "Zx9" + "Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk"
        helper = self.repo / "scripts" / "activate-nixos.sh"
        helper.write_text(
            helper.read_text().replace(
                'echo "activate-nixos: eval failed" >&2',
                f'echo "activate-nixos: unsafe override https://u:p@h.invalid/x?k={token}" >&2',
            )
        )
        r = self.drive("--host", "hpp-1", STUB_DRYRUN_RC=1)
        self.assertEqual(r.returncode, 1, r.stderr)
        path, ev = self.evidence(r)
        # mentions an override: never copied, even when it is not one we know
        self.assertEqual(
            ev["message"],
            "helper rejected an override input; details in the local stage log",
        )
        self.assertNotIn(token, path.read_text())


class RunDirectory(Harness):
    """#4: never create the run directory inside any Git repository."""

    def git_repo(self, name):
        d = self.tmp / name
        d.mkdir()
        subprocess.run(
            ["git", *GIT_FLAGS, "init", "-q"], cwd=d, env=self.env, check=True
        )
        return d

    def assert_refused(self, r, created):
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("inside a Git repository", r.stderr)
        self.assertFalse(created.exists())
        self.assertEqual(self.calls("ssh"), [])
        self.assertEqual(self.helper_calls(), [])

    def test_run_dir_inside_another_checkout_is_refused(self):
        other = self.git_repo("primary")
        target = other / "logs" / "deep" / "run"
        r = self.drive("--host", "hpp-1", "--run-dir", str(target))
        self.assert_refused(r, other / "logs")

    def test_default_state_dir_inside_a_repository_is_refused(self):
        dotfiles = self.git_repo("dotfiles")
        r = self.drive("--host", "hpp-1", XDG_STATE_HOME=dotfiles / "state")
        self.assert_refused(r, dotfiles / "state")

    def test_git_environment_cannot_hide_a_repository(self):
        other = self.git_repo("primary")
        r = self.drive(
            "--host", "hpp-1", "--run-dir", str(other / "logs"),
            GIT_DIR=str(self.tmp / "nowhere.git"), GIT_CEILING_DIRECTORIES=str(self.tmp),
        )  # fmt: skip
        self.assert_refused(r, other / "logs")

    def test_run_dir_inside_a_git_dir_is_refused(self):
        other = self.git_repo("primary")
        r = self.drive(
            "--host", "hpp-1", "--run-dir", str(other / ".git" / "logs" / "x")
        )
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertFalse((other / ".git" / "logs" / "x").exists())


class LocalSecrets(Harness):
    """#5: the effective --local-secrets input is in the record."""

    def secrets_repo(self, path):
        path.mkdir(parents=True)
        subprocess.run(
            ["git", *GIT_FLAGS, "init", "-q"], cwd=path, env=self.env, check=True
        )
        (path / "a").write_text("1")
        subprocess.run(
            ["git", *GIT_FLAGS, "add", "a"], cwd=path, env=self.env, check=True
        )
        subprocess.run(
            ["git", *GIT_FLAGS, "commit", "-qm", "x"],
            cwd=path,
            env=self.env,
            check=True,
        )
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=path,
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return head

    def local(self, **env):
        r = self.drive("--host", "hpp-1", "--local-secrets", **env)
        self.assertEqual(r.returncode, 0, r.stderr)
        _, ev = self.evidence(r)
        self.assertTrue(all("--local-secrets" in a for a in self.helper_calls()))
        return ev["inputs"]["local_secrets"]

    def test_sibling_checkout_is_recorded_with_head_and_dirty_counts(self):
        sibling = self.tmp / "nix-secrets"
        head = self.secrets_repo(sibling)
        clean = self.local()
        self.assertEqual(
            clean,
            {
                "path": str(sibling.resolve()),
                "head": head,
                "dirty": False,
                "dirty_paths": 0,
                "matches_lock": False,
            },
        )
        (sibling / "a").write_text("changed")
        (sibling / "b").write_text("new")
        dirty = self.local()
        self.assertEqual((dirty["dirty"], dirty["dirty_paths"]), (True, 2))
        self.assertNotEqual(clean, dirty)
        self.assertNotIn("changed", json.dumps(dirty))

    def test_nix_secrets_path_wins_and_is_home_relative(self):
        self.secrets_repo(self.tmp / "nix-secrets")
        explicit = self.home / "src" / "secrets-b"
        head = self.secrets_repo(explicit)
        rec = self.local(NIX_SECRETS_PATH=explicit)
        self.assertEqual(rec["path"], "~/src/secrets-b")
        self.assertEqual(rec["head"], head)

    def test_missing_checkout_fails_the_inputs_stage(self):
        r = self.drive("--host", "hpp-1", "--local-secrets")
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "inputs")
        self.assertIn("cannot find the nix-secrets checkout", ev["message"])
        self.assertEqual(self.helper_calls(), [])


class LaunchFailures(Harness):
    """#6: after admission a command that cannot be launched is a failed
    stage, and evidence.json is still written."""

    def restricted_path(self, *tools):
        d = self.tmp / "bin"
        d.mkdir()
        for tool in tools:
            found = shutil.which(tool, path=self.env["PATH"].split(os.pathsep, 1)[1])
            self.assertIsNotNone(found, tool)
            (d / tool).symlink_to(found)
        return f"{self.stubs}{os.pathsep}{d}"

    def test_helper_that_cannot_be_launched(self):
        path = self.restricted_path("git", "python3", "basename")  # no bash
        r = self.drive("--host", "hpp-1", PATH=path)
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "inputs")
        self.assertEqual(ev["message"], "cannot launch bash: No such file or directory")
        self.assertEqual(self.statuses(ev)["evidence"], "passed")

    def test_ssh_that_cannot_be_launched(self):
        (self.stubs / "ssh").unlink()
        path = self.restricted_path("git", "python3", "basename", "bash")
        r = self.drive("--host", "hpp-1", PATH=path)
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "pre-state")
        self.assertEqual(ev["message"], "cannot launch ssh: No such file or directory")

    def test_git_that_cannot_be_launched_refuses_before_any_connection(self):
        # The run directory's Git membership cannot be checked: fail closed.
        path = self.restricted_path("python3", "basename", "bash")
        r = self.drive("--host", "hpp-1", PATH=path)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("cannot ask git", r.stderr)
        self.assertEqual(self.calls("ssh"), [])
        self.assertEqual(self.helper_calls(), [])


class CycleTwo(Harness):
    """Re-review fixes: URL paths, cross-filesystem discovery, and the post
    snapshot surviving a probe disconnect."""

    def overrides(self, *pairs):
        argv = ["--host", "hpp-1"]
        for name, value in pairs:
            argv += ["--override-input", name, value]
        r = self.drive(*argv)
        self.assertEqual(r.returncode, 0, r.stderr)
        path, ev = self.evidence(r)
        return path.read_text(), ev["inputs"]["override_inputs"]

    def test_credential_bearing_url_paths_keep_only_the_origin(self):
        token = "k3yAbcd" + "Efgh1234"  # 15 chars: below the generic token pattern
        url = f"https://files.example.invalid:8443/s/{token}/download/input.tar.gz"
        text, recs = self.overrides(("blob", url))
        self.assertEqual(
            recs,
            [
                {
                    "name": "blob",
                    "value": "https://files.example.invalid:8443",
                    "fingerprint": fingerprint(url),
                }
            ],
        )
        self.assertNotIn(token, text)
        self.assertNotIn("download", text)

    def test_different_pins_stay_distinguishable(self):
        rev_a, rev_b = "a" * 40, "b" * 40
        text, recs = self.overrides(
            ("x", f"https://h.invalid/t/secretpath.tar.gz?rev={rev_a}"),
            ("y", f"https://h.invalid/t/secretpath.tar.gz?rev={rev_b}"),
            ("z", "https://h.invalid/t/otherpath.tar.gz"),
        )
        self.assertEqual([r["value"] for r in recs], ["https://h.invalid"] * 3)
        self.assertEqual([r.get("rev") for r in recs], [rev_a, rev_b, None])
        self.assertEqual(len({r["fingerprint"] for r in recs}), 3)
        self.assertNotIn("secretpath", text)

    def test_recognised_refs_keep_their_location_and_revision(self):
        rev = "0123456789abcdef0123456789abcdef01234567"
        value = f"git+ssh://git@github.com/ianepreston/nix-secrets.git?ref=main&rev={rev}&shallow=1"
        _, recs = self.overrides(("nix-secrets", value), ("gh", "github:o/r/feature-x"))
        self.assertEqual(
            recs,
            [
                {"name": "nix-secrets", "value": "git+ssh://<redacted>@github.com/ianepreston/nix-secrets.git", "fingerprint": fingerprint(value), "rev": rev, "ref": "main"},
                {"name": "gh", "value": "github:o/r/feature-x", "fingerprint": fingerprint("github:o/r/feature-x")},
            ],
        )  # fmt: skip

    def test_membership_check_discovers_across_filesystems(self):
        real_git = shutil.which("git", path=self.env["PATH"].split(os.pathsep, 1)[1])
        wrapper = self.stubs / "git"
        wrapper.write_text(
            SHEBANG
            + 'case "$*" in *"rev-parse --git-dir"*) printf \'discovery=%s\\n\' "${GIT_DISCOVERY_ACROSS_FILESYSTEM-unset}" >> "$STUB_LOG.git" ;; esac\n'
            + f'exec {real_git} "$@"\n'
        )  # fmt: skip
        wrapper.chmod(0o755)
        r = self.drive("--host", "hpp-1", GIT_DISCOVERY_ACROSS_FILESYSTEM="0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(f"{self.log}.git").read_text(), "discovery=1\n")

    def test_probe_disconnect_keeps_the_verified_post_snapshot(self):
        r = self.drive("--host", "hpp-1", "--switch", "--probe", "true", STUB_SSH_DROP_PROBE=1)  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        _, ev = self.evidence(r)
        self.assertEqual(ev["failed_stage"], "post")
        self.assertIn("ssh to ipreston@hpp-1 failed", ev["message"])
        self.assertEqual(ev["post"]["current_system"], NEW)
        self.assertEqual(ev["post"]["generation"], 42)
        self.assertTrue(ev["generation_changed"])
        self.assertEqual(
            ev["probes"], [{"index": 1, "id": probe_id("true"), "exit_code": None}]
        )


class HelperDiagnostics(Harness):
    """A helper diagnostic that echoes an override value never reaches the
    evidence or the printed summaries: only the input name and fingerprint."""

    TOKEN = "k3yAbcd" + "Efgh1234"  # split so ripsecrets ignores the fixture
    URL = f"https://files.example.invalid/s/{TOKEN}/download/input.tar.gz?download=1"

    def run_rejected(self, mode):
        r = self.drive("--host", "hpp-1", "--override-input", "blob", self.URL, STUB_REJECT_OVERRIDE=mode)  # fmt: skip
        self.assertEqual(r.returncode, 1, r.stderr)
        path, ev = self.evidence(r)
        text = path.read_text()
        for leak in (self.TOKEN, "/s/", "input.tar.gz", "download=1"):
            self.assertNotIn(leak, text)
            self.assertNotIn(leak, r.stderr)
            self.assertNotIn(leak, r.stdout)
        marker = f"<input:blob {fingerprint(self.URL)}>"
        return ev, marker

    def test_rejected_override_in_dry_run_reports_name_and_fingerprint(self):
        ev, marker = self.run_rejected("dry-run")
        self.assertEqual(ev["failed_stage"], "inputs")
        self.assertEqual(
            ev["message"],
            f"helper diagnostic concerns override input {marker}; details in the local stage log",
        )
        self.assertEqual(self.statuses(ev)["inputs"], "failed")
        # the full diagnostic stays in the local log
        log = Path(next(s["log"] for s in ev["stages"] if s["name"] == "inputs"))
        self.assertIn(self.TOKEN, log.read_text())

    def test_url_path_alone_in_a_later_stage_is_masked(self):
        ev, marker = self.run_rejected("preflight-path")
        self.assertEqual(ev["failed_stage"], "preflight")
        self.assertIn(marker, ev["message"])

    def test_masks_cover_raw_decoded_and_parsed_forms(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "vh", REPO / "scripts" / "validate-host.py"
        )
        vh = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vh)
        encoded = self.URL.replace("/s/", "/s%2F", 1)
        masks = dict(vh.input_masks([("blob", encoded)]))
        marker = f"<input:blob {fingerprint(encoded)}>"
        for form in (encoded, self.URL, self.URL.split("?")[0], "download=1"):
            self.assertEqual(masks.get(form), marker, form)


class MalformedInputs(Harness):
    """Override values that urllib cannot (re)parse never crash a run: the
    evidence is written, with the name and fingerprint, and leaks nothing."""

    SECRET = "p%5B" + "ss"  # split so ripsecrets ignores the fixture
    AUTH_URL = (
        "https://build" + ":" + SECRET + "@" + "artifacts.example.invalid/source.tar.gz"
    )
    BROKEN_URL = "https://[unbalanced" + "Qw8x/src.tar.gz?k=v"

    def drive_with(self, value, **env):
        r = self.drive("--host", "hpp-1", "--override-input", "src", value, **env)
        path = Path(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None
        self.assertIsNotNone(path, r.stderr)
        self.assertTrue(path.is_file(), r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        return r, path.read_text(), json.loads(path.read_text())

    def assert_no_leak(self, r, text, *leaks):
        for leak in leaks:
            self.assertNotIn(leak, text)
            self.assertNotIn(leak, r.stdout)
            self.assertNotIn(leak, r.stderr)

    def test_encoded_bracket_in_password_passes_and_leaks_nothing(self):
        r, text, ev = self.drive_with(self.AUTH_URL)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            ev["inputs"]["override_inputs"],
            [{"name": "src", "value": "https://artifacts.example.invalid", "fingerprint": fingerprint(self.AUTH_URL)}],
        )  # fmt: skip
        self.assert_no_leak(r, text, self.SECRET, "p[ss", "build:")

    def test_encoded_bracket_in_password_rejected_by_the_helper(self):
        r, text, ev = self.drive_with(self.AUTH_URL, STUB_REJECT_OVERRIDE="dry-run")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual(ev["failed_stage"], "inputs")
        self.assertIn(f"<input:src {fingerprint(self.AUTH_URL)}>", ev["message"])
        self.assert_no_leak(r, text, self.SECRET, "p[ss", "build:")

    def test_unbalanced_bracket_does_not_crash(self):
        r, text, ev = self.drive_with(self.BROKEN_URL)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            ev["inputs"]["override_inputs"],
            [{"name": "src", "value": "https://<unparsable>", "fingerprint": fingerprint(self.BROKEN_URL)}],
        )  # fmt: skip
        self.assert_no_leak(r, text, "unbalanced", "src.tar.gz")

    def test_unbalanced_bracket_rejected_by_the_helper(self):
        r, text, ev = self.drive_with(self.BROKEN_URL, STUB_REJECT_OVERRIDE="dry-run")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn(f"<input:src {fingerprint(self.BROKEN_URL)}>", ev["message"])
        self.assert_no_leak(r, text, "unbalanced", "src.tar.gz")

    def test_mask_building_never_raises(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("vh", REPO / "scripts" / "validate-host.py")  # fmt: skip
        vh = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vh)
        for value in (
            self.AUTH_URL,
            self.BROKEN_URL,
            "http://[::1",
            "x://]",
            "%%%",
            "",
        ):
            with self.subTest(value=value):
                masks = dict(vh.input_masks([("v", value)]))
                if len(value) >= 4:
                    self.assertEqual(masks[value], f"<input:v {fingerprint(value)}>")
                vh.describe_input("v", value)
        masks = dict(vh.input_masks([("src", self.AUTH_URL)]))
        for form in (self.SECRET, "p[ss", "artifacts.example.invalid"):
            self.assertIn(form, masks)


class ObserveClock(unittest.TestCase):
    """stage_observe on fake clocks (#1090): SPAN_CLOCK and WALL_CLOCK count a
    runner suspend, AWAKE_CLOCK does not, and SLEEP pauses during one (it
    returns after its full awake time). No process, ssh or host involved."""

    def setUp(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("vh", REPO / "scripts" / "validate-host.py")  # fmt: skip
        self.vh = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.vh)
        self.vh.say = lambda msg: self.said.append(msg)
        self.said = []
        self.span = self.awake = 0.0
        self.wall = 1_800_000_000.0
        self.check_s = 0.5
        self.sleeps = []
        self.starts = []  # SPAN_CLOCK at each check start
        self.suspend_in_sleep = {}  # nth sleep -> seconds suspended
        self.suspend_in_check = {}  # nth check -> seconds suspended
        self.wall_step_in_check = {}  # nth check -> wall clock step
        self.suspend_on_awake_read = {}  # nth AWAKE_CLOCK read -> seconds
        self.raise_in_check = {}  # nth check -> exception
        self.awake_reads = 0
        self.vh.SPAN_CLOCK = lambda: self.span
        self.vh.AWAKE_CLOCK = self.read_awake
        self.vh.WALL_CLOCK = lambda: self.wall
        self.vh.SLEEP = self.sleep

    def fallback(self):
        """No suspend-aware clock: SPAN_CLOCK is time.monotonic, which (on
        Linux/macOS) stops during a suspend like AWAKE_CLOCK."""
        self.vh.SPAN_CLOCK_NAME = "monotonic"
        self.vh.SPAN_CLOCK = lambda: self.awake

    def advance(self, seconds, suspended=0.0):
        self.span += seconds + suspended
        self.wall += seconds + suspended
        self.awake += seconds

    def read_awake(self):
        self.awake_reads += 1
        self.advance(0, self.suspend_on_awake_read.get(self.awake_reads, 0.0))
        return self.awake

    def sleep(self, seconds):
        self.assertGreater(seconds, 0)
        self.assertLessEqual(seconds, self.vh.SLEEP_SLICE)
        self.sleeps.append(seconds)
        self.advance(seconds, self.suspend_in_sleep.get(len(self.sleeps), 0.0))

    def health(self, stage, probes):
        self.starts.append(self.span)
        n = len(self.starts)
        self.advance(self.check_s, self.suspend_in_check.get(n, 0.0))
        self.wall += self.wall_step_in_check.get(n, 0.0)
        if n in self.raise_in_check:
            raise self.raise_in_check[n]
        probes.append({"index": 1, "id": "0" * 12, "exit_code": 0})
        state = {"current_system": OLD, "system_state": "running", "failed_unit_count": 0}  # fmt: skip
        return state, []

    def observe(self, observe=180, interval=30):
        import types

        v = types.SimpleNamespace(
            a=types.SimpleNamespace(observe=observe, interval=interval),
            evidence={
                "post": {"current_system": OLD},
                "failed_units": {"new": [], "changed": []},
            },
            health=self.health,
        )
        v.observe_failed = lambda *args: self.vh.Validation.observe_failed(v, *args)
        try:
            return self.vh.Validation.stage_observe(v), v.evidence["observe"]
        except self.vh.StageFailed as e:
            return e, v.evidence["observe"]

    def span_of(self, rec):
        import datetime

        parse = datetime.datetime.fromisoformat
        return (parse(rec["finished_at"]) - parse(rec["started_at"])).total_seconds()

    def assert_passed(self, result, rec):
        self.assertIsInstance(result, str, getattr(result, "summary", ""))
        self.assertTrue(rec["ok"])

    def assert_failed(self, result, rec, *fragments):
        self.assertIsInstance(result, self.vh.StageFailed, result)
        self.assertFalse(rec["ok"])
        for fragment in fragments:
            self.assertIn(fragment, result.summary)
        # every exit path leaves timing; with a suspend-aware clock and no
        # wall step the wall span and elapsed_s agree
        self.assertIsNotNone(rec["finished_at"])
        self.assertGreaterEqual(self.span_of(rec), 0)
        if rec["suspend_aware"] and not rec["wall_step"]:
            self.assertLessEqual(abs(self.span_of(rec) - rec["elapsed_s"]), 1)

    def test_awake_window_samples_every_interval(self):
        summary, rec = self.observe()
        self.assert_passed(summary, rec)
        self.assertEqual(rec["iterations"], 6)
        self.assertEqual(rec["max_gap_s"], 30)
        self.assertEqual(rec["max_late_s"], 0)
        self.assertEqual(rec["elapsed_s"], 180)
        self.assertEqual(rec["slow_checks"], 0)
        self.assertEqual(rec["wall_skew_s"], 0)
        self.assertIs(rec["suspend_aware"], True)
        self.assertIsNone(rec["breach"])
        self.assertIsNone(rec["cadence_warning"])
        self.assertIsNone(rec["wall_step"])
        self.assertEqual(self.span_of(rec), 180)
        self.assertEqual(summary, "6 check(s) over 180s passed (interval 30s, largest gap 30s)")  # fmt: skip
        self.assertEqual(self.said, [])

    def test_suspend_during_a_wait_fails_before_the_late_check_runs(self):
        # The #1090 run: asleep ~55s into a 180s window, for ~17 minutes.
        self.suspend_in_sleep = {55: 1000.0}
        err, rec = self.observe()
        self.assert_failed(err, rec, "observation check 2:", "unsampled")
        self.assertEqual(len(self.starts), 1)  # check 2 never ran
        self.assertEqual(rec["iterations"], 1)
        self.assertGreaterEqual(rec["max_late_s"], 990)  # minus the wait left
        self.assertEqual(rec["late_tolerance_s"], 29.5)  # the wait after check 1
        self.assertEqual(rec["breach"]["kind"], "late")
        self.assertEqual(rec["breach"]["check"], 2)
        self.assertGreater(rec["breach"]["value_s"], rec["breach"]["tolerance_s"])
        self.assertGreaterEqual(rec["elapsed_s"], 1000)  # not the 60s awake
        self.assertGreaterEqual(self.span_of(rec), 1000)
        self.assertNotIn("last", rec)

    def test_suspend_during_a_check_fails(self):
        for nth in (2, 6):  # mid-window, and the last check
            with self.subTest(check=nth):
                self.setUp()
                self.suspend_in_check = {nth: 300.0}
                err, rec = self.observe()
                self.assert_failed(err, rec, f"observation check {nth}:", "suspended")
                self.assertEqual(rec["iterations"], nth)
                self.assertGreaterEqual(rec["max_late_s"], 300)

    def test_short_window_with_a_long_interval_still_detects_a_suspend(self):
        # --observe 3s --interval 300s: the tolerance is the 3s wait, not 300s.
        for where in ("wait", "check"):
            with self.subTest(where=where):
                self.setUp()
                if where == "wait":
                    self.suspend_in_sleep = {1: 120.0}
                else:
                    self.suspend_in_check = {1: 120.0}
                err, rec = self.observe(observe=3, interval=300)
                self.assert_failed(err, rec, "unsampled")
                self.assertGreaterEqual(rec["max_late_s"], 117)  # minus the wait left
                self.assertEqual(rec["late_tolerance_s"], 3)

    def test_no_unmeasured_gap_between_lateness_and_check_start(self):
        # A suspend right after the deadline is read, before the check's
        # awake clock is: it is counted against that check.
        self.suspend_on_awake_read = {1: 120.0}
        err, rec = self.observe(observe=3, interval=3)
        self.assert_failed(err, rec, "suspended")
        self.assertGreaterEqual(rec["max_late_s"], 120)

    def test_a_wall_clock_step_is_recorded_and_never_changes_the_verdict(self):
        for step in (120.0, -120.0):
            with self.subTest(step=step):
                self.setUp()
                self.check_s = 45.0  # awake, slower than the interval
                self.wall_step_in_check = {1: step}
                summary, rec = self.observe(observe=60, interval=30)
                self.assert_passed(summary, rec)
                # check 1 at 30s runs to 75s, past the 60s window
                self.assertEqual(rec["elapsed_s"], 75)
                # finished_at is the wall clock as read, clamped at started_at
                self.assertEqual(self.span_of(rec), 195 if step > 0 else 0)
                self.assertEqual(rec["wall_step"], "forward" if step > 0 else "backward")  # fmt: skip
                self.assertEqual(rec["wall_skew_s"], round(step))
                self.assertEqual(rec["max_late_s"], 0)
                self.assertEqual(len(self.said), 1)
                self.assertIn("wall clock moved", self.said[0])

    def test_fallback_uses_wall_time_and_says_so(self):
        self.fallback()
        summary, rec = self.observe()
        self.assert_passed(summary, rec)
        self.assertEqual(rec["clock"], "monotonic")
        self.assertIs(rec["suspend_aware"], False)
        self.assertTrue(summary.endswith(", suspend detection by wall clock only)"))
        for kind in ("wait", "check"):
            with self.subTest(kind=kind):
                self.setUp()
                self.fallback()
                if kind == "wait":
                    self.suspend_in_sleep = {40: 600.0}
                else:
                    self.suspend_in_check = {6: 600.0}
                err, rec = self.observe()
                self.assert_failed(err, rec, "unsampled")
                self.assertGreaterEqual(rec["max_late_s"], 600)
                self.assertGreaterEqual(rec["wall_skew_s"], 600)

    def test_a_slow_awake_check_is_flagged_not_failed(self):
        for check_s, slow in ((45.0, 4), (180.0, 1)):
            with self.subTest(check_s=check_s):
                self.setUp()
                self.check_s = check_s
                summary, rec = self.observe()
                self.assert_passed(summary, rec)
                self.assertEqual(rec["max_late_s"], 0)
                self.assertEqual(rec["max_check_s"], round(check_s))
                self.assertEqual(rec["slow_checks"], slow)
                self.assertIn(f"slower than the interval, longest {round(check_s)}s", summary)  # fmt: skip

    def test_a_suspended_sleep_overruns_by_at_most_one_slice(self):
        # time.sleep pauses during the suspend and then finishes its slice.
        self.suspend_in_sleep = {1: 2.0}
        summary, rec = self.observe(observe=3, interval=3)
        self.assert_passed(summary, rec)
        self.assertLessEqual(self.starts[0], 3 + self.vh.SLEEP_SLICE)
        self.assertLessEqual(max(self.sleeps), self.vh.SLEEP_SLICE)
        # a resume after the deadline: the check starts within one slice
        self.setUp()
        self.suspend_in_sleep = {3: 10.0}
        err, rec = self.observe(observe=3, interval=3)
        self.assert_failed(err, rec, "unsampled")
        self.assertLessEqual(rec["max_late_s"], 10 + self.vh.SLEEP_SLICE)

    def test_a_check_that_raises_still_records_its_timing(self):
        self.suspend_in_check = {6: 300.0}
        self.raise_in_check = {6: self.vh.StageFailed("ssh dropped")}
        err, rec = self.observe()
        self.assertIsInstance(err, self.vh.StageFailed)
        self.assertGreaterEqual(rec["elapsed_s"], 450)
        self.assertEqual(self.span_of(rec), rec["elapsed_s"])
        self.assertGreaterEqual(rec["max_late_s"], 300)

    def test_an_interrupted_wait_records_elapsed_and_lateness(self):
        import types

        def interrupted(seconds):
            self.advance(seconds, 500.0)
            raise KeyboardInterrupt

        self.vh.SLEEP = interrupted
        v = types.SimpleNamespace(
            a=types.SimpleNamespace(observe=180, interval=30),
            evidence={"post": {"current_system": OLD}},
            health=self.health,
        )
        with self.assertRaises(KeyboardInterrupt):
            self.vh.Validation.stage_observe(v)
        rec = v.evidence["observe"]
        self.assertGreaterEqual(rec["elapsed_s"], 500)
        self.assertGreaterEqual(rec["max_late_s"], 470)
        self.assertEqual(self.span_of(rec), rec["elapsed_s"])

    def test_one_check_has_no_gap(self):
        summary, rec = self.observe(observe=3, interval=30)
        self.assert_passed(summary, rec)
        self.assertEqual(rec["iterations"], 1)
        self.assertIsNone(rec["max_gap_s"])
        self.assertNotIn("largest gap", summary)

    def test_lateness_is_recorded_unrounded(self):
        self.suspend_in_check = {1: 2.4}
        err, rec = self.observe(observe=3, interval=1)
        self.assert_failed(err, rec, "2.400s suspended (tolerance 2.000s)")
        self.assertEqual(rec["max_late_s"], 2.4)
        self.assertEqual(rec["late_tolerance_s"], 2)
        self.assertEqual(rec["breach"], {"check": 1, "kind": "suspended", "value_s": 2.4, "tolerance_s": 2})  # fmt: skip

    def test_a_breach_just_over_the_tolerance_never_reads_as_equal(self):
        self.suspend_in_check = {1: 2.0001}
        err, rec = self.observe(observe=3, interval=1)
        self.assert_failed(err, rec, "2.001s suspended (tolerance 2.000s)")
        self.assertEqual(rec["breach"]["value_s"], 2.001)

    def test_the_breach_is_the_offending_value_not_an_earlier_tolerated_one(self):
        # check 2 starts 22.5s late (tolerated, wait 29.5s); check 3 is left
        # a 7s wait and starts 10s late: that is the breach.
        self.suspend_in_sleep = {57: 25.0, 59: 15.0}
        err, rec = self.observe()
        self.assert_failed(err, rec, "observation check 3:")
        self.assertEqual(rec["breach"]["check"], 3)
        self.assertEqual(rec["breach"]["kind"], "late")
        self.assertGreater(rec["breach"]["value_s"], rec["breach"]["tolerance_s"])
        self.assertEqual(rec["breach"]["value_s"], 10)
        self.assertEqual(rec["breach"]["tolerance_s"], 7)
        self.assertEqual(rec["max_late_s"], 22.5)  # earlier, tolerated

    def test_tolerance_is_relative_to_the_next_due_time(self):
        # A 29s check leaves a 1s wait: a 5s suspend in it fails (it would
        # pass against a full-interval tolerance).
        self.check_s = 29.0
        self.suspend_in_sleep = {31: 5.0}
        err, rec = self.observe()
        self.assert_failed(err, rec, "observation check 2:", "after it was due")
        self.assertEqual(rec["breach"]["tolerance_s"], 2)

    def test_tolerated_delays_that_add_up_raise_a_cadence_warning(self):
        # check 2 starts 27.5s late (tolerated): a 57.5s gap at a 30s interval
        self.suspend_in_sleep = {58: 29.0}
        summary, rec = self.observe()
        self.assert_passed(summary, rec)
        self.assertIsNone(rec["breach"])
        self.assertGreaterEqual(rec["max_gap_s"], 57)
        self.assertEqual(rec["cadence_warning"]["check"], 2)
        self.assertEqual(rec["cadence_warning"]["expected_s"], 30)
        self.assertIn("WARNING cadence gap", summary)

    def parse(self, *argv):
        with open(os.devnull, "w") as null:
            stderr, sys.stderr = sys.stderr, null
            try:
                return self.vh.parse_args(["--host", "hpp-1", *argv])
            finally:
                sys.stderr = stderr

    def test_only_the_observe_interval_is_capped(self):
        for argv in (["--interval", "99999999999999999999h"], ["--interval", "5h"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                self.parse("--observe", "3s", *argv)
        # the timeout options parse exactly as before #1090
        for option in ("--probe-timeout", "--build-timeout", "--switch-timeout"):
            with self.subTest(option=option):
                dest = option[2:].replace("-", "_")
                self.assertEqual(getattr(self.parse(option, "169h"), dest), 169 * 3600)
                self.assertEqual(getattr(self.parse(option, "99999999999999999999h"), dest), 99999999999999999999 * 3600)  # fmt: skip
        a = self.parse("--observe", "3s", "--interval", "4h")
        summary, rec = self.observe(observe=a.observe, interval=a.interval)
        self.assert_passed(summary, rec)

    def test_span_clock_choice_and_fallback(self):
        import types

        def clocks(**names):
            def gettime(clock):
                if clock == "broken":
                    raise OSError(22, "Invalid argument")
                return 123.0

            return types.SimpleNamespace(monotonic=time.monotonic, clock_gettime=gettime, **names)  # fmt: skip

        cases = [
            ("linux", clocks(CLOCK_BOOTTIME=7), "CLOCK_BOOTTIME"),
            ("linux", clocks(CLOCK_MONOTONIC_RAW=4), "monotonic"),  # stops on Linux
            ("linux", clocks(CLOCK_BOOTTIME="broken"), "monotonic"),
            ("darwin", clocks(CLOCK_MONOTONIC_RAW=4), "CLOCK_MONOTONIC_RAW"),
            ("darwin", clocks(), "monotonic"),
            ("darwin", clocks(CLOCK_MONOTONIC_RAW="broken"), "monotonic"),
            ("freebsd14", clocks(CLOCK_BOOTTIME=7), "monotonic"),
        ]
        for platform, module, expected in cases:
            with self.subTest(platform=platform, expected=expected):
                name, read = self.vh.span_clock(platform, module)
                self.assertEqual(name, expected)
                if expected == "monotonic":
                    self.assertIs(read, time.monotonic)
                else:
                    self.assertEqual(read(), 123.0)
        # and the real one on this platform
        name, read = self.vh.span_clock()
        platform = "linux" if sys.platform.startswith("linux") else sys.platform
        preferred = {"linux": "CLOCK_BOOTTIME", "darwin": "CLOCK_MONOTONIC_RAW"}
        # the fallback is right where the preferred clock is unavailable
        self.assertIn(name, {preferred.get(platform, "monotonic"), "monotonic"})
        if name == "monotonic" and hasattr(time, preferred.get(platform, "")):
            with self.assertRaises(OSError):
                time.clock_gettime(getattr(time, preferred[platform]))
        first = read()
        self.assertGreaterEqual(read(), first)

    def test_a_read_failure_marker_never_copies_remote_text(self):
        import types

        leak = "s3cr3t-remote-text"
        for reads, output in (
            (True, f"VALIDATE-READ-FAILED {leak}\n"),
            (True, "VALIDATE-READ-FAILED\n"),
            (False, f"VALIDATE-READ-FAILED {leak}\nVALIDATE-PROBE-RC n 0\n"),
        ):
            with self.subTest(reads=reads, output=output):
                self.vh.run_capture = lambda *_a, **_k: (98 if reads else 0, output)
                v = types.SimpleNamespace(host="hpp-1", target="ipreston@hpp-1", log=lambda _s: None)  # fmt: skip
                try:
                    self.vh.Validation.remote(v, "observe", lambda _n: "probe", 5, reads=reads)  # fmt: skip
                except self.vh.StageFailed as e:
                    self.assertTrue(reads)
                    self.assertNotIn(leak, e.summary)
                    self.assertIn("unrecognised key", e.summary)
                else:
                    self.assertFalse(reads)
        self.vh.run_capture = lambda *_a, **_k: (98, "VALIDATE-READ-FAILED system_state\n")  # fmt: skip
        v = types.SimpleNamespace(host="hpp-1", target="ipreston@hpp-1", log=lambda _s: None)  # fmt: skip
        with self.assertRaises(self.vh.StageFailed) as cm:
            self.vh.Validation.remote(v, "pre-state", lambda _n: "state", 5, reads=True)  # fmt: skip
        self.assertEqual(cm.exception.summary, "required read 'system_state' failed on hpp-1; stopping")  # fmt: skip


class HostileProbeOutput(Harness):
    """A probe's stdout imitating remote.sh's read-failure marker is neither
    obeyed nor copied into the evidence (#1090 review)."""

    LEAK = "s3cr3t-probe-stdout"

    def test_marker_in_probe_stdout_is_not_a_read_failure(self):
        for rc, result in ((0, "passed"), (3, "failed")):
            with self.subTest(rc=rc):
                probe = f"echo 'VALIDATE-READ-FAILED {self.LEAK}'; exit {rc}"
                r = self.drive("--host", "hpp-1", "--probe", probe, "--observe", "2s", "--interval", "1s")  # fmt: skip
                path, ev = self.evidence(r)
                self.assertEqual(ev["result"], result, r.stderr)
                text = path.read_text()
                self.assertNotIn(self.LEAK, text)
                self.assertNotIn(self.LEAK, r.stderr)
                if rc:
                    self.assertIn("exited 3", ev["message"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
