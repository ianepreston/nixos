#!/usr/bin/env python3
"""Exercise the actual Task templates with inert restore commands (#1017).

By default systemctl is simulated. --systemd PATH uses real systemd in the
disposable NixOS test guest, whose only writers are harmless sleep services.
SSH runs its input locally; no command connects to a host or restores app data.
"""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("taskfile", type=Path)
parser.add_argument("--systemd", default="")
args = parser.parse_args()
TASKFILE = args.taskfile.resolve()
WRITER = "recovery-writer.service"
OTHER = "recovery-other.service"
BLOCKED = "recovery-blocked.service"
MISSING = "recovery-missing.service"
# Models of podman-bookorbit's init (#1122): root tini forwarding SIGTERM to
# an app running as another uid, with and without CAP_KILL.
INIT_APP = "recovery-init-app.service"
INIT_NOKILL = "recovery-init-nokill.service"
SHAPES = ("volume", "pg", "sqlite")


class RecoveryStopTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "trace"
        self.trace.touch()
        self.env = dict(os.environ, TRACE=str(self.trace))
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        # Run the remote command locally with the program on stdin, as ssh would.
        self.write_command("ssh", 'exec bash -c "${@: -1}"\n')
        self.write_command("sudo", 'if [ "$1" = -u ]; then shift 2; fi\nexec "$@"\n')
        self.write_command("getent", "exit 0\n")
        self.write_command(
            "zcat", "printf '\\\\connect recovery_test\\nSELECT 1;\\n'\n"
        )
        for name in ("restic", "dropdb", "createdb", "psql", "install"):
            failure = f'if [ "${{FAIL_STEP:-}}" = {name} ]; then exit 42; fi\n'
            if name == "restic":
                failure = (
                    'if [ "${FAIL_STEP:-}" = restic ]; then\n'
                    '  case " $* " in *" restore "*) exit 42 ;; esac\n'
                    "fi\n"
                )
            if name == "psql":
                # Match psql's input consumption so pipefail cannot turn a
                # successful replay into a scheduling-dependent SIGPIPE.
                failure += "cat >/dev/null\n"
            self.write_command(
                name,
                f'printf "%s\\n" "{name} $*" >>"$TRACE"\n' + failure,
            )
        systemctl = 'printf "%s\\n" "systemctl $*" >>"$TRACE"\n'
        if args.systemd:
            systemctl += f'exec {shlex.quote(args.systemd)} "$@"\n'
            self.real_systemctl("stop", WRITER, OTHER)
        else:
            systemctl += f"""
case "$1" in
  stop)
    case "$2" in
      {BLOCKED}|{MISSING}) echo "Cannot stop $2" >&2; exit 1 ;;
    esac
    ;;
  show)
    if [ "${{SHOW_FAIL:-}}" = 1 ]; then exit 1; fi
    printf '%s\\n' "${{STOP_STATE-inactive}}"
    ;;
esac
"""
        self.write_command("systemctl", systemctl)

    def real_systemctl(self, *arguments):
        return subprocess.check_output([args.systemd, *arguments], text=True).strip()

    def start_init_model(self, unit):
        """Start unit and wait until tini's child runs as nobody.

        A SIGTERM that arrives before setpriv drops the uid would be
        forwarded root to root and hide the missing capability.
        """
        # Clears a previous subtest's failed state; errors on a unit that
        # was never loaded.
        subprocess.run([args.systemd, "reset-failed", unit], capture_output=True)
        self.real_systemctl("start", unit)
        for _ in range(100):
            main = self.real_systemctl("show", unit, "--property=MainPID", "--value")
            children = Path(f"/proc/{main}/task/{main}/children")
            try:
                for child in children.read_text().split():
                    status = Path(f"/proc/{child}/status").read_text()
                    if "\nUid:\t65534\t" in status:
                        return
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        self.fail(f"{unit}: tini's child never ran as nobody")

    def write_command(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def restore(self, shape, units=(WRITER, OTHER), **environment):
        self.trace.write_text("")
        # Only the install shim can see these SQLite paths; it never writes.
        result = subprocess.run(
            [
                "task",
                "--taskfile",
                str(TASKFILE),
                f"_restore-{shape}",
                "HOST=disposable",
                "APP=recovery-test",
                "UNITS=" + " ".join(units),
                "PATHS=/recovery-test/state",
                "DB=recovery_test",
                "SWAPS=/recovery-test/staged:/recovery-test/live:root",
            ],
            env=dict(self.env, **environment),
            capture_output=True,
            text=True,
        )
        self.output = result.stdout + result.stderr
        self.calls = self.trace.read_text().splitlines()
        return result.returncode

    def assert_no_restore_or_start(self):
        self.assertTrue(self.calls, self.output)
        for call in self.calls:
            self.assertTrue(
                call.startswith(("systemctl stop ", "systemctl show ")),
                f"Unsafe command reached: {call}\n{self.output}",
            )

    def test_stop_failure_at_each_position_aborts_all_shapes(self):
        if args.systemd:
            self.real_systemctl("start", BLOCKED)
        for shape in SHAPES:
            for units in ((BLOCKED, OTHER), (WRITER, BLOCKED)):
                with self.subTest(shape=shape, units=units):
                    self.assertNotEqual(self.restore(shape, units), 0, self.output)
                    self.assertIn(f"Failed to stop {BLOCKED}", self.output)
                    self.assertEqual(self.calls[-1], f"systemctl stop {BLOCKED}")
                    self.assert_no_restore_or_start()
                    if args.systemd:
                        self.assertEqual(
                            self.real_systemctl("is-active", BLOCKED), "active"
                        )

    def test_missing_unit_aborts_all_shapes(self):
        for shape in SHAPES:
            with self.subTest(shape=shape):
                self.assertNotEqual(self.restore(shape, (MISSING,)), 0, self.output)
                self.assertIn(f"Failed to stop {MISSING}", self.output)
                self.assert_no_restore_or_start()

    def test_stopped_and_running_units_restore_then_start(self):
        for shape in SHAPES:
            for running in (False, True):
                with self.subTest(shape=shape, running=running):
                    if args.systemd:
                        self.real_systemctl("stop", WRITER, OTHER)
                        if running:
                            self.real_systemctl("start", WRITER, OTHER)
                    self.assertEqual(self.restore(shape), 0, self.output)
                    self.assertEqual(
                        self.calls[:4],
                        [
                            f"systemctl stop {WRITER}",
                            f"systemctl show {WRITER} --property=ActiveState --value",
                            f"systemctl stop {OTHER}",
                            f"systemctl show {OTHER} --property=ActiveState --value",
                        ],
                    )
                    self.assertIn(" unlock", self.calls[4])
                    self.assertIn(" restore latest --target / --delete ", self.calls[5])
                    self.assertEqual(
                        self.calls[-2:],
                        [f"systemctl start {WRITER}", f"systemctl start {OTHER}"],
                    )
                    if shape == "pg":
                        self.assertTrue(self.calls[6].startswith("dropdb "))
                        self.assertTrue(self.calls[7].startswith("createdb "))
                        self.assertTrue(self.calls[8].startswith("psql "))
                    elif shape == "sqlite":
                        self.assertTrue(self.calls[6].startswith("install "))

    def test_restore_errors_never_start_units(self):
        for shape in SHAPES:
            steps = ["restic"]
            if shape == "pg":
                steps += ["dropdb", "createdb", "psql"]
            elif shape == "sqlite":
                steps += ["install"]
            for step in steps:
                with self.subTest(shape=shape, step=step):
                    if args.systemd:
                        self.real_systemctl("start", WRITER, OTHER)
                    self.assertNotEqual(self.restore(shape, FAIL_STEP=step), 0)
                    self.assertFalse(
                        any(c.startswith("systemctl start ") for c in self.calls),
                        self.output,
                    )
                    if args.systemd:
                        for unit in (WRITER, OTHER):
                            self.assertEqual(
                                self.real_systemctl(
                                    "show", unit, "--property=ActiveState", "--value"
                                ),
                                "inactive",
                            )

    @unittest.skipUnless(args.systemd, "Needs real systemd and capabilities")
    def test_container_init_stop_all_shapes(self):
        for shape in SHAPES:
            with self.subTest(shape=shape, unit=INIT_APP):
                # Forwarded SIGTERM: exit 143 is the clean result, so the
                # unit stops inactive and the restore proceeds.
                self.start_init_model(INIT_APP)
                self.assertEqual(self.restore(shape, (INIT_APP,)), 0, self.output)
                self.assertIn(" restore latest --target / --delete ", self.calls[3])
                self.assertEqual(self.calls[-1], f"systemctl start {INIT_APP}")
                self.real_systemctl("stop", INIT_APP)
                self.assertEqual(
                    self.real_systemctl(
                        "show", INIT_APP, "--property=Result", "--value"
                    ),
                    "success",
                )
            with self.subTest(shape=shape, unit=INIT_NOKILL):
                # `systemctl stop` returns 0 but tini dies with status 1 on
                # EPERM: the unit is failed, and that must still abort.
                self.start_init_model(INIT_NOKILL)
                self.assertNotEqual(self.restore(shape, (INIT_NOKILL,)), 0)
                self.assertIn(
                    f"{INIT_NOKILL} is failed after stop; aborting restore",
                    self.output,
                )
                self.assertEqual(
                    self.calls[-2:],
                    [
                        f"systemctl stop {INIT_NOKILL}",
                        f"systemctl show {INIT_NOKILL} --property=ActiveState --value",
                    ],
                )
                self.assert_no_restore_or_start()
                self.assertEqual(
                    self.real_systemctl(
                        "show", INIT_NOKILL, "--property=ExecMainStatus", "--value"
                    ),
                    "1",
                )

    @unittest.skipIf(args.systemd, "Fault injection uses the simulated systemctl")
    def test_unexpected_or_unreadable_state_aborts_all_shapes(self):
        for shape in SHAPES:
            for state in ("active", "activating", "deactivating", "failed", ""):
                with self.subTest(shape=shape, state=state):
                    self.assertNotEqual(self.restore(shape, STOP_STATE=state), 0)
                    self.assertIn("after stop; aborting restore", self.output)
                    self.assert_no_restore_or_start()
            with self.subTest(shape=shape, show_failure=True):
                self.assertNotEqual(self.restore(shape, SHOW_FAIL="1"), 0)
                self.assert_no_restore_or_start()


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
