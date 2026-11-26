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

# Values a word-splitting or re-parsing implementation would mangle or run.
ODD_UNIT = "odd unit $(touch PWNED) 'q' \"d\";x.service"
ODD_PATH = "/srv/a b/`touch PWNED`/semi;colon/$HOME/*"

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
        self.stub(
            "ssh",
            'rec ssh "$@"\nbash -se\n# Drain whatever is left, as a real ssh would.\ncat >/dev/null\n',
        )
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
                    "-p",
                    "22",
                    "-oForwardAgent=yes",
                    "ipreston@h",
                    "sudo bash -se",
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
        cases = {
            "unknown recovery app: nope": ({"app": good}, "nope"),
            "unknown recovery kind: tape": ({"app": self.entry("tape")}, "app"),
            "unknown recovery kind: null": ({"app": {**good, "kind": None}}, "app"),
            "units must be a list": ({"app": {**good, "units": "a b"}}, "app"),
            "paths must be a list": ({"app": {**good, "paths": ["ok", ""]}}, "app"),
            "database must be": ({"app": self.entry("postgres")}, "app"),
            "swaps must be a list": ({"app": self.entry("sqlite", swaps=None)}, "app"),
            "swap owner must be": (
                {
                    "app": self.entry(
                        "sqlite", swaps=[{"staged": "a", "live": "b", "owner": ""}]
                    )
                },
                "app",
            ),
            "health retries must be": (
                {
                    "app": {
                        **good,
                        "health": {
                            "url": "u",
                            "expect": "200",
                            "retries": "30",
                            "sleep": 2,
                        },
                    }
                },
                "app",
            ),
            "health expect must be": (
                {
                    "app": {
                        **good,
                        "health": {
                            "url": "u",
                            "expect": 200,
                            "retries": 30,
                            "sleep": 2,
                        },
                    }
                },
                "app",
            ),
        }
        for message, (manifest, app) in cases.items():
            with self.subTest(message=message):
                self.assertEqual(
                    self.run_driver(manifest, "app", "--app", app, "--host", "h"),
                    1,
                    self.output,
                )
                self.assertIn(message, self.output)
                self.assertNotIn("jq: error", self.output)
                self.assertEqual(self.calls, [])

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
                self.assertEqual(code, 11, self.output)
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
        self.assertIn(["ssh", "-p", "2222", "op@10.0.0.9", "bash -se"], self.calls)
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
        self.assertEqual(self.run_driver(manifest, *args), 1, self.output)
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
        self.assertEqual(self.run_driver(manifest, "all", "--host", "h"), 1)
        self.assertIn("recovery app c: units must be a list", self.output)
        self.assertEqual(self.calls, [])

    def task(self, *args):
        return self.run_cmd(["task", "--taskfile", str(self.taskfile), *args])

    def test_task_app_passes_variables_and_defaults(self):
        manifest = {"app": self.entry(units=[ODD_UNIT])}
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        mf = f"MANIFEST_FILE={self.root / 'manifest.json'}"
        self.assertEqual(
            self.task("recovery:app", "APP=app", "HOST=h", mf), 0, self.output
        )
        self.assertEqual(
            self.calls[0],
            ["ssh", "-p", "22", "-oForwardAgent=yes", "ipreston@h", "sudo bash -se"],
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
            ["ssh", "-p", "2222", "-oForwardAgent=yes", "op@10.0.0.9", "sudo bash -se"],
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
        self.assertEqual(self.calls[0], ["ssh", "-p", "22", "ipreston@h", "bash -se"])
        self.assertIn("x: 200 OK", self.output)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
