#!/usr/bin/env python3
"""Offline tests for scripts/recovery.sh and scripts/_recovery/remote.sh (#1025).

    recovery-test.py REPO

REPO holds taskfiles/recovery.yaml and scripts/. Task-level tests reach it
through a root Taskfile with the same `recovery:` include as the real one
(the other includes are irrelevant here). ssh runs the program it is
fed locally with `bash -se`; systemctl, restic, sudo, postgres tools, install,
getent, curl, sleep and nix are recording stubs. Nothing connects to a host or
touches app data. The #1017 stop-failure matrix lives in recovery-stop-test.py.
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

REPO = Path(sys.argv[1]).resolve()
DRIVER = REPO / "scripts" / "recovery.sh"
BASH = shutil.which("bash")

RESTORE_SHELL = "| sudo bash -se"
PROBE_SHELL = "| bash -se"

# Values a word-splitting or re-parsing implementation would mangle or run.
ODD_UNIT = "odd unit $(touch PWNED) 'q' \"d\";x.service"
ODD_PATH = "/srv/a b/`touch PWNED`/semi;colon/$HOME/*"

# ssh stand-in. It records its options and, instead of the base64 program,
# the remote shell the program is piped into; then it runs the remote command
# locally the way a real ssh would. SSH_MODE simulates transports:
#   normal      stdin is forwarded unless -n was given
#   stdin-null  ssh_config `StdinNull yes`: stdin is always discarded
#   noexec      the connection "succeeds" but nothing runs on the target
SSH_STUB = r"""args=("$@")
cmd=${args[$((${#args[@]} - 1))]}
shown=$cmd
case "$cmd" in
  "printf %s '"*"' | base64 -d | "*) shown="| ${cmd##*base64 -d | }" ;;
esac
rec ssh "${args[@]:0:$((${#args[@]} - 1))}" "$shown"
null=0
for a in "${args[@]}"; do [ "$a" != -n ] || null=1; done
case "${SSH_MODE:-normal}" in
  noexec) exit 0 ;;
  stdin-null) null=1 ;;
esac
if [ "$null" = 1 ]; then
  bash -c "$cmd" </dev/null
else
  bash -c "$cmd"
fi
"""

RECORD = """rec() {
  local line
  line=$(printf ' %q' "$@")
  printf '%s\\n' "${line# }" >>"$TRACE"
}
"""

# A pg_dumpall-shaped dump: the target section sits between its \\connect and
# the next CREATE DATABASE / \\connect.
DUMP = r"""CREATE ROLE app_db;
\connect template1
SELECT 'template1';
CREATE DATABASE "app_db";
\connect "app_db"
SELECT 'mine';
SELECT 'mine too';
CREATE DATABASE other;
\connect other
SELECT 'other';
"""


class RecoveryDriverTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "trace"
        self.codes = self.root / "codes"
        self.codes.write_text("")
        (self.root / "dump.sql").write_text(DUMP)
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            TRACE=str(self.trace),
            CURL_CODES=str(self.codes),
            DUMP=str(self.root / "dump.sql"),
            NIX_MANIFEST=str(self.root / "manifest.json"),
        )
        self.stub("ssh", SSH_STUB)
        self.stub(
            "sudo",
            'if [ "$1" = -u ]; then rec sudo "$1" "$2"; shift 2; fi\nexec "$@"\n',
        )
        self.stub(
            "systemctl",
            'rec systemctl "$@"\n[ "$1" != show ] || echo inactive\n',
        )
        self.stub(
            "restic",
            'rec restic "$@"\n'
            'case " $* " in *" restore "*) [ -z "${RESTIC_FAIL:-}" ] || '
            '[ "$RESTIC_FAIL" != "$(cat "$TRACE" | grep -c " restore ")" ] || exit 11 ;; esac\n',
        )
        for name in ("dropdb", "createdb", "install", "sleep"):
            self.stub(name, f'rec {name} "$@"\n')
        self.stub("zcat", 'rec zcat "$@"\ncat "$DUMP"\n')
        self.stub(
            "psql",
            'rec psql "$@"\nwhile IFS= read -r l; do rec psql-stdin "$l"; done\n',
        )
        self.stub("getent", 'rec getent "$@"\nexit "${GETENT_RC:-0}"\n')
        # One code per line in $CURL_CODES, consumed in order; then 200.
        self.stub(
            "curl",
            'rec curl "$@"\ncode=$(head -n1 "$CURL_CODES")\n'
            'tail -n +2 "$CURL_CODES" >"$CURL_CODES.n"; mv "$CURL_CODES.n" "$CURL_CODES"\n'
            'printf "%s" "${code:-200}"\n',
        )
        self.stub("nix", 'rec nix "$@"\ncat "$NIX_MANIFEST"\n')
        self.taskfile = self.root / "Taskfile.yaml"
        self.taskfile.write_text(
            "version: '3'\nincludes:\n"
            f"  recovery: {json.dumps(str(REPO / 'taskfiles' / 'recovery.yaml'))}\n"
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{BASH}\nset -euo pipefail\n{RECORD}{body}")
        path.chmod(0o755)

    def entry(self, kind="volume", **fields):
        entry = {
            "kind": kind,
            "order": 10,
            "units": ["app.service"],
            "paths": ["/var/lib/app"],
            "database": None,
            "swaps": [],
            "health": None,
        }
        entry.update(fields)
        return entry

    def run_driver(self, manifest, *args, env=None):
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        return self.run_cmd(
            [str(DRIVER), *args, "--manifest-file", str(self.root / "manifest.json")],
            env,
        )

    def run_cmd(self, argv, env=None):
        self.trace.write_text("")
        result = subprocess.run(
            argv,
            cwd=self.root,
            env=dict(self.env, **(env or {})),
            capture_output=True,
            text=True,
        )
        self.output = result.stdout + result.stderr
        self.calls = [shlex.split(line) for line in self.trace.read_text().splitlines()]
        return result.returncode

    def commands(self):
        return [call[0] for call in self.calls]

    def restore_call(self):
        return next(c for c in self.calls if c[0] == "restic" and "restore" in c)

    def assert_not_pwned(self):
        self.assertFalse((self.root / "PWNED").exists(), "a value was executed")

    def test_volume_shape_preserves_structured_values(self):
        manifest = {
            "app": self.entry(units=[ODD_UNIT, "b.service"], paths=[ODD_PATH, "/x"])
        }
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h"),
            0,
            self.output,
        )
        repo = [
            "-r",
            "/mnt/backups/restic/h",
            "--password-file",
            "/run/secrets/restic/password",
        ]
        self.assertEqual(
            self.calls,
            [
                [
                    "ssh",
                    "-n",
                    "-p",
                    "22",
                    "-oForwardAgent=yes",
                    "ipreston@h",
                    RESTORE_SHELL,
                ],
                ["systemctl", "stop", ODD_UNIT],
                ["systemctl", "show", ODD_UNIT, "--property=ActiveState", "--value"],
                ["systemctl", "stop", "b.service"],
                ["systemctl", "show", "b.service", "--property=ActiveState", "--value"],
                ["restic", *repo, "unlock"],
                [
                    "restic",
                    *repo,
                    "--retry-lock",
                    "10m",
                    "restore",
                    "latest",
                    "--target",
                    "/",
                    "--delete",
                    "--include",
                    ODD_PATH,
                    "--include",
                    "/x",
                ],
                ["systemctl", "start", ODD_UNIT],
                ["systemctl", "start", "b.service"],
            ],
        )
        self.assertIn("(volume-only) from h's restic repo", self.output)
        self.assert_not_pwned()

    def test_postgres_shape_replays_only_its_section(self):
        for paths in ([], ["/var/lib/a b"]):
            with self.subTest(paths=paths):
                manifest = {
                    "pg": self.entry("postgres", database="app_db", paths=paths)
                }
                self.assertEqual(
                    self.run_driver(manifest, "app", "--app", "pg", "--host", "h"),
                    0,
                    self.output,
                )
                self.assertEqual(
                    self.restore_call()[-2 - 2 * len(paths) :],
                    ["--include", "/var/backup/postgresql"]
                    + [x for p in paths for x in ("--include", p)],
                )
                replay = [
                    c
                    for c in self.calls
                    if c[0] in ("dropdb", "createdb", "psql", "zcat")
                ]
                self.assertEqual(
                    sorted(map(tuple, replay)),
                    sorted(
                        [
                            ("dropdb", "--if-exists", "app_db"),
                            ("createdb", "-O", "app_db", "app_db"),
                            ("zcat", "/var/backup/postgresql/all.sql.gz"),
                            ("psql", "-v", "ON_ERROR_STOP=1", "app_db"),
                        ]
                    ),
                )
                self.assertEqual(
                    [c[1] for c in self.calls if c[0] == "psql-stdin"],
                    ["SELECT 'mine';", "SELECT 'mine too';"],
                )
                order = self.commands()
                self.assertLess(order.index("restic"), order.index("dropdb"))
                self.assertEqual(self.calls[-1], ["systemctl", "start", "app.service"])

    def test_sqlite_shape_resolves_glob_and_owner(self):
        live_dir = self.root / "live dir"
        (live_dir / "profile 1").mkdir(parents=True)
        (live_dir / "profile 1" / "app.db").touch()
        glob = f"{live_dir}/*/app.db"
        swaps = [
            {"staged": "/var/backup/sqlite/s/app.db", "live": glob, "owner": "@env@"},
            {
                "staged": "/var/backup/sqlite/s/b c.db",
                "live": "/var/lib/s/b c.db",
                "owner": "svc",
            },
        ]
        manifest = {
            "s": self.entry(
                "sqlite", swaps=swaps, paths=["/var/lib/s", "/var/backup/sqlite/s"]
            )
        }
        for rc, user in (("0", "server-prod"), ("2", "server-dev")):
            with self.subTest(user=user):
                code = self.run_driver(
                    manifest, "app", "--app", "s", "--host", "h", env={"GETENT_RC": rc}
                )
                self.assertEqual(code, 0, self.output)
                self.assertEqual(
                    [c for c in self.calls if c[0] == "install"],
                    [
                        [
                            "install",
                            "-o",
                            user,
                            "-g",
                            "servers",
                            "-m",
                            "0640",
                            "/var/backup/sqlite/s/app.db",
                            f"{live_dir}/profile 1/app.db",
                        ],
                        [
                            "install",
                            "-o",
                            "svc",
                            "-g",
                            "servers",
                            "-m",
                            "0640",
                            "/var/backup/sqlite/s/b c.db",
                            "/var/lib/s/b c.db",
                        ],
                    ],
                )
                order = self.commands()
                self.assertEqual(order[1], "getent")
                self.assertLess(order.index("restic"), order.index("install"))
                self.assertEqual(self.calls[-1], ["systemctl", "start", "app.service"])

    def test_sqlite_glob_must_match_exactly_one(self):
        live_dir = self.root / "live"
        for count in (0, 2):
            with self.subTest(count=count):
                shutil.rmtree(live_dir, ignore_errors=True)
                for i in range(count):
                    (live_dir / str(i)).mkdir(parents=True)
                    (live_dir / str(i) / "app.db").touch()
                swaps = [
                    {
                        "staged": "/s/app.db",
                        "live": f"{live_dir}/*/app.db",
                        "owner": "x",
                    }
                ]
                manifest = {"s": self.entry("sqlite", swaps=swaps)}
                self.assertNotEqual(
                    self.run_driver(manifest, "app", "--app", "s", "--host", "h"), 0
                )
                self.assertIn(f"matched {count} files, expected 1", self.output)
                self.assertNotIn("install", self.commands())
                self.assertNotIn(["systemctl", "start", "app.service"], self.calls)

    def test_unknown_app_kind_and_malformed_entries_never_connect(self):
        good = self.entry()
        probe = {"url": "u", "expect": "200", "retries": 30, "sleep": 2}
        cases = {
            "unknown recovery app: nope": ({"app": good}, "nope", 5),
            "unknown recovery kind: tape": ({"app": self.entry("tape")}, "app", 1),
            "unknown recovery kind: null": ({"app": {**good, "kind": None}}, "app", 1),
            "units must be a list": ({"app": {**good, "units": "a b"}}, "app", 5),
            "paths must be a list": ({"app": {**good, "paths": ["ok", 3]}}, "app", 5),
            "database must be": ({"app": self.entry("postgres")}, "app", 5),
            "swaps must be a list": (
                {"app": self.entry("sqlite", swaps=None)},
                "app",
                5,
            ),
            "swap owner must be": (
                {"app": self.entry("sqlite", swaps=[{"staged": "a", "live": "b"}])},
                "app",
                5,
            ),
            "health must be an object": ({"app": {**good, "health": "x"}}, "app", 5),
            "health retries must be": (
                {"app": {**good, "health": {**probe, "retries": None}}},
                "app",
                5,
            ),
            "health url must be": (
                {"app": {**good, "health": {**probe, "url": 5}}},
                "app",
                5,
            ),
        }
        for message, (manifest, app, status) in cases.items():
            with self.subTest(message=message):
                self.assertEqual(
                    self.run_driver(manifest, "app", "--app", app, "--host", "h"),
                    status,
                    self.output,
                )
                self.assertIn(message, self.output)
                self.assertNotIn("jq: error", self.output)
                self.assertEqual(self.calls, [])

    def test_schema_valid_inputs_the_old_dispatcher_accepted(self):
        # Empty strings are valid under the Nix types; empty list elements
        # vanished from the old space-joined lists; numeric probe settings
        # may be strings (`sleep 0.5`); an empty `expect` meant 200.
        health = {"url": "http://u/", "expect": "", "retries": "2", "sleep": "0.5"}
        manifest = {
            "app": self.entry(units=["", "a.service"], paths=["/p", ""], health=health)
        }
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h"),
            0,
            self.output,
        )
        self.assertEqual(self.apps_in_order(), ["a.service"])
        self.assertEqual(self.restore_call()[-2:], ["--include", "/p"])
        self.assertIn("Asserting HTTP 200 on app (http://u/)", self.output)
        self.assertIn("app: 200 OK", self.output)
        self.codes.write_text("500\n500\n")
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h"), 201
        )
        self.assertEqual(
            [c for c in self.calls if c[0] == "sleep"], [["sleep", "0.5"]] * 2
        )
        manifest = {"pg": self.entry("postgres", database="", paths=[])}
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "pg", "--host", "h"), 0
        )
        self.assertIn(["dropdb", "--if-exists", ""], self.calls)

    def test_restore_failure_propagates_without_start_or_probe(self):
        health = {
            "url": "http://127.0.0.1:1/",
            "expect": "200",
            "retries": 3,
            "sleep": 1,
        }
        for kind, extra in (("volume", {}), ("postgres", {"database": "app_db"})):
            with self.subTest(kind=kind):
                manifest = {"app": self.entry(kind, health=health, **extra)}
                code = self.run_driver(
                    manifest,
                    "app",
                    "--app",
                    "app",
                    "--host",
                    "h",
                    env={"RESTIC_FAIL": "1"},
                )
                self.assertEqual(code, 201, self.output)
                self.assertNotIn(["systemctl", "start", "app.service"], self.calls)
                self.assertEqual(
                    [c for c in self.calls if c[0] == "ssh"], [self.calls[0]]
                )
                self.assertNotIn("dropdb", self.commands())

    def test_health_probe_polls_then_reports(self):
        health = {
            "url": "http://127.0.0.1:9/it's",
            "expect": "302",
            "retries": 3,
            "sleep": 5,
        }
        manifest = {"app": self.entry(health=health)}
        args = (
            "app",
            "--app",
            "app",
            "--host",
            "h",
            "--dest",
            "10.0.0.9",
            "--ssh-port",
            "2222",
            "--target-user",
            "op",
        )
        self.codes.write_text("000\n302\n")
        self.assertEqual(self.run_driver(manifest, *args), 0, self.output)
        self.assertIn(
            ["ssh", "-n", "-p", "2222", "op@10.0.0.9", PROBE_SHELL], self.calls
        )
        self.assertEqual(
            [c for c in self.calls if c[0] in ("curl", "sleep")],
            [
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", health["url"]],
                ["sleep", "5"],
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", health["url"]],
            ],
        )
        self.assertIn("app: 302 OK", self.output)
        self.codes.write_text("500\n500\n500\n")
        self.assertEqual(self.run_driver(manifest, *args), 201, self.output)
        self.assertIn(
            "app: did not return 302 within 3x5s (last code: 500)", self.output
        )

    def apps_in_order(self):
        return [c[2] for c in self.calls if c[:2] == ["systemctl", "stop"]]

    def test_all_restores_every_app_in_order_despite_probes(self):
        health = {
            "url": "http://127.0.0.1:1/",
            "expect": "200",
            "retries": 2,
            "sleep": 1,
        }
        manifest = {
            name: self.entry(order=order, units=[f"{name}.service"], health=health)
            for name, order in (("c", 30), ("a", 10), ("b app", 20))
        }
        # Run through Task with a pipe on stdin, as an operator script would.
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        code = self.run_cmd(
            [
                "bash",
                "-c",
                f"printf 'x\\ny\\n' | task --taskfile {shlex.quote(str(self.taskfile))} "
                "recovery:all HOST=h MANIFEST_HOST='flake host' REPO_MOUNT=/mnt/dev-backups SOURCE_HOST=src",
            ]
        )
        self.assertEqual(code, 0, self.output)
        self.assertEqual(
            self.calls[0],
            [
                "nix",
                "eval",
                "--json",
                ".#nixosConfigurations.flake host.config.myRecovery.manifest",
            ],
        )
        self.assertEqual(
            self.apps_in_order(), ["a.service", "b app.service", "c.service"]
        )
        self.assertEqual(sum(c[0] == "curl" for c in self.calls), 3)
        self.assertEqual(self.restore_call()[2], "/mnt/dev-backups/restic/src")

    def test_all_stops_at_first_failure_and_validates_first(self):
        manifest = {
            name: self.entry(order=order, units=[f"{name}.service"])
            for name, order in (("a", 10), ("b", 20), ("c", 30))
        }
        self.assertNotEqual(
            self.run_driver(manifest, "all", "--host", "h", env={"RESTIC_FAIL": "2"}), 0
        )
        self.assertEqual(self.apps_in_order(), ["a.service", "b.service"])
        self.assertNotIn(["systemctl", "start", "b.service"], self.calls)
        manifest["c"]["units"] = "c.service"
        self.assertEqual(self.run_driver(manifest, "all", "--host", "h"), 201)
        self.assertIn("recovery app c: units must be a list", self.output)
        self.assertEqual(self.calls, [])

    def task(self, *args, env=None, manifest=None):
        if manifest is not None:
            (self.root / "manifest.json").write_text(json.dumps(manifest))
        return self.run_cmd(["task", "--taskfile", str(self.taskfile), *args], env)

    def test_task_app_passes_variables_and_defaults(self):
        manifest = {"app": self.entry(units=[ODD_UNIT])}
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        mf = f"MANIFEST_FILE={self.root / 'manifest.json'}"
        self.assertEqual(
            self.task("recovery:app", "APP=app", "HOST=h", mf), 0, self.output
        )
        self.assertEqual(
            self.calls[0],
            [
                "ssh",
                "-n",
                "-p",
                "22",
                "-oForwardAgent=yes",
                "ipreston@h",
                RESTORE_SHELL,
            ],
        )
        self.assertEqual(self.calls[1], ["systemctl", "stop", ODD_UNIT])
        self.assertEqual(self.restore_call()[2], "/mnt/backups/restic/h")
        self.assertEqual(
            self.task(
                "recovery:app",
                "APP=app",
                "HOST=h",
                mf,
                "DEST=10.0.0.9",
                "SOURCE_HOST=amos1",
                "SSH_PORT=2222",
                "TARGET_USER=op",
                "REPO_MOUNT=/mnt/prod-backups",
            ),
            0,
            self.output,
        )
        self.assertEqual(
            self.calls[0],
            [
                "ssh",
                "-n",
                "-p",
                "2222",
                "-oForwardAgent=yes",
                "op@10.0.0.9",
                RESTORE_SHELL,
            ],
        )
        self.assertEqual(self.restore_call()[2], "/mnt/prod-backups/restic/amos1")
        self.assertIn(
            "Restoring app on h (volume-only) from amos1's restic repo", self.output
        )
        self.assert_not_pwned()

    def test_hidden_templates_keep_their_encodings(self):
        code = self.task(
            "recovery:_restore-sqlite",
            "HOST=h",
            "APP=s",
            "UNITS=a.service  b.service",
            "PATHS=/p/one /p/two",
            "SWAPS=/st/x:/lv/x:@env@ /st/y:/lv/y:own:er",
        )
        self.assertEqual(code, 0, self.output)
        self.assertEqual(self.apps_in_order(), ["a.service", "b.service"])
        self.assertEqual(
            self.restore_call()[-4:], ["--include", "/p/one", "--include", "/p/two"]
        )
        self.assertEqual(
            [c[2] + " " + c[-2] + " " + c[-1] for c in self.calls if c[0] == "install"],
            ["server-prod /st/x /lv/x", "own:er /st/y /lv/y"],
        )
        self.assertEqual(
            self.task(
                "recovery:_restore-pg",
                "HOST=h",
                "APP=p",
                "UNITS=p.service",
                "DB=app_db",
            ),
            0,
        )
        self.assertEqual(
            self.restore_call()[-2:], ["--include", "/var/backup/postgresql"]
        )
        self.assertEqual(
            self.task("recovery:_health", "HOST=h", "APP=x", "URL=http://u/"),
            0,
            self.output,
        )
        self.assertEqual(
            self.calls[0], ["ssh", "-n", "-p", "22", "ipreston@h", PROBE_SHELL]
        )
        self.assertIn("x: 200 OK", self.output)

    # ssh transports that drop or never run the program, and Task statuses.
    probe = {"url": "http://127.0.0.1:1/", "expect": "200", "retries": 2, "sleep": 1}

    def test_stdin_null_still_runs_restore_and_probe(self):
        manifest = {"app": self.entry(health=self.probe)}
        env = {"SSH_MODE": "stdin-null"}
        self.codes.write_text("500\n500\n")
        code = self.run_driver(manifest, "app", "--app", "app", "--host", "h", env=env)
        self.assertEqual(code, 201, self.output)
        self.assertIn(["systemctl", "start", "app.service"], self.calls)
        self.assertEqual(sum(c[0] == "curl" for c in self.calls), 2)
        self.assertIn("did not return 200", self.output)
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h", env=env),
            0,
            self.output,
        )
        self.assertIn("app: 200 OK", self.output)

    def test_program_that_never_runs_fails_closed(self):
        manifest = {"app": self.entry(health=self.probe)}
        env = {"SSH_MODE": "noexec"}
        code = self.run_driver(manifest, "app", "--app", "app", "--host", "h", env=env)
        self.assertEqual(code, 201, self.output)
        self.assertIn(
            "app restore: the remote program did not report completion", self.output
        )
        self.assertEqual(self.commands(), ["ssh"])
        code = self.task(
            "recovery:_health", "HOST=h", "APP=x", "URL=http://u/", env=env
        )
        self.assertNotEqual(code, 0, self.output)
        self.assertIn(
            "x health probe: the remote program did not report completion", self.output
        )
        code = self.task("recovery:all", "HOST=h", env=env, manifest=manifest)
        self.assertNotEqual(code, 0, self.output)

    def test_marker_is_hidden_and_must_carry_this_runs_nonce(self):
        manifest = {"app": self.entry()}
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h"), 0
        )
        self.assertNotIn("RECOVERY-DONE", self.output)
        # A marker from some other run (a fixed string) is not enough.
        self.stub("ssh", 'rec ssh "$@"\necho "RECOVERY-DONE 0000"\n')
        self.assertEqual(
            self.run_driver(manifest, "app", "--app", "app", "--host", "h"), 201
        )

    def test_task_exit_codes_match_the_old_dispatcher(self):
        health = self.probe
        good = {"app": self.entry(health=health)}
        cases = [
            (
                "app restic failure",
                ["recovery:app", "APP=app", "HOST=h"],
                good,
                {"RESTIC_FAIL": "1"},
                201,
            ),
            (
                "app probe failure",
                ["recovery:app", "APP=app", "HOST=h"],
                good,
                {"CODES": "500\n500\n"},
                201,
            ),
            (
                "all restic failure",
                ["recovery:all", "HOST=h"],
                good,
                {"RESTIC_FAIL": "1"},
                201,
            ),
            ("unknown app", ["recovery:app", "APP=nope", "HOST=h"], good, {}, 5),
            (
                "unknown kind",
                ["recovery:app", "APP=app", "HOST=h"],
                {"app": self.entry("tape")},
                {},
                1,
            ),
            (
                "template restic failure",
                [
                    "recovery:_restore-volume",
                    "HOST=h",
                    "APP=a",
                    "UNITS=a.service",
                    "PATHS=/p",
                ],
                {},
                {"RESTIC_FAIL": "1"},
                11,
            ),
            (
                "template probe failure",
                [
                    "recovery:_health",
                    "HOST=h",
                    "APP=a",
                    "URL=http://u/",
                    "RETRIES=1",
                    "SLEEP=0.5",
                ],
                {},
                {"CODES": "500\n"},
                1,
            ),
            ("app success", ["recovery:app", "APP=app", "HOST=h"], good, {}, 0),
        ]
        for name, args, manifest, env, status in cases:
            with self.subTest(name=name):
                self.codes.write_text(env.pop("CODES", ""))
                self.assertEqual(
                    self.task("--exit-code", *args, env=env, manifest=manifest),
                    status,
                    self.output,
                )

    def test_hidden_health_accepts_old_inputs(self):
        self.codes.write_text("500\n")
        code = self.task(
            "recovery:_health",
            "HOST=h",
            "APP=x",
            "URL=",
            "EXPECT=",
            "RETRIES=2",
            "SLEEP=0.5",
        )
        self.assertEqual(code, 0, self.output)
        self.assertEqual([c for c in self.calls if c[0] == "sleep"], [["sleep", "0.5"]])
        self.assertEqual([c[-1] for c in self.calls if c[0] == "curl"], ["", ""])
        self.assertIn("Asserting HTTP 200 on x ()", self.output)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
