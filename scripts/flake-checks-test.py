#!/usr/bin/env python3
"""Offline tests for scripts/flake-checks.sh (#1021).

`nix` is a logging stub on PATH that answers from a synthetic flake described
in JSON (configurations, per-system checks, injected eval/build failures, a
stale lock, the machine's system and remote builders). Nothing is evaluated,
built or fetched, and no builder is contacted. The tests cover discovery
(a new configuration or check is picked up without editing the driver),
failure propagation (stale lock, failed eval, failed build -> nonzero),
platform refusal, DEFERRED reporting, and that every nix call keeps
--no-update-lock-file and never rewrites the lock.

usage: flake-checks-test.py REPO_ROOT
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
DRIVER = REPO / "scripts" / "flake-checks.sh"
# The Nix build sandbox has no /usr/bin/env: run the driver with this bash.
BASH = os.path.realpath(shutil.which("bash") or "/bin/bash")
PYTHON = os.path.realpath(sys.executable)
FLAKE = "/synthetic/flake"

NIX_STUB = r"""
import json, os, sys

args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
fx = json.load(open(os.environ["STUB_FIXTURE"]))


def attr_path(installable):
    flake, _, path = installable.partition("#")
    if os.path.realpath(flake) != os.path.realpath(os.environ["STUB_FLAKE"]):
        sys.exit(f"stub nix: unexpected flake {flake!r}")
    parts, cur, quoted = [], "", False
    for ch in path:
        if ch == '"':
            quoted = not quoted
        elif ch == "." and not quoted:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def lookup(parts):
    node = fx["flake"]
    for p in parts:
        if not isinstance(node, dict) or p not in node:
            print(f"error: attribute '{p}' missing", file=sys.stderr)
            sys.exit(1)
        node = node[p]
    return node


def failing(key, parts):
    for prefix in fx.get(key, []):
        if ".".join(parts).startswith(prefix):
            print(f"error: injected failure for {prefix}", file=sys.stderr)
            sys.exit(1)


if args[:2] == ["config", "show"]:
    value = fx["config"].get(args[2])
    if value is None:
        sys.exit(1)
    print(value)
elif args[:2] == ["flake", "metadata"]:
    if "--no-update-lock-file" not in args:
        sys.exit("stub nix: metadata without --no-update-lock-file")
    if fx.get("stale_lock"):
        print("error: cannot write modified lock file (use --no-update-lock-file)", file=sys.stderr)
        sys.exit(1)
elif args[0] == "eval":
    if fx.get("stale_lock"):
        sys.exit(1)
    installable = next(a for a in args[1:] if "#" in a)
    parts = attr_path(installable)
    failing("fail_eval", parts)
    apply = args[args.index("--apply") + 1] if "--apply" in args else None
    if "--raw" in args:
        assert parts[-1] == "drvPath", parts
        lookup(parts[:2])
        print(f"/nix/store/0000-{parts[1]}.drv", end="")
    elif apply == "builtins.attrNames":
        print(json.dumps(sorted(lookup(parts))))
    elif apply and "mapAttrs" in apply:
        print(json.dumps({k: f"/nix/store/0000-{k}.drv" for k in lookup(parts)}))
    elif apply and "isFunction" in apply:
        lookup(parts)
        print(json.dumps(parts[0] not in fx.get("bad_shape", [])))
    else:
        sys.exit(f"stub nix: unexpected eval {args}")
elif args[0] == "build":
    installable = next(a for a in args[1:] if "#" in a)
    parts = attr_path(installable)
    lookup(parts)
    failing("fail_build", parts)
else:
    sys.exit(f"stub nix: unexpected command {args}")
"""


def checks(*names):
    return {n: {} for n in names}


def fixture(**over):
    fx = {
        "config": {"system": "aarch64-darwin", "extra-platforms": "x86_64-darwin"},
        "flake": {
            "nixosConfigurations": {"hpp-1": {}, "terra": {}},
            "darwinConfigurations": {"work": {}},
            "homeConfigurations": {"penguin": {}},
            "checks": {
                "aarch64-darwin": checks("pre-commit", "doc-links"),
                "x86_64-linux": checks("pre-commit", "doc-links", "vm-test"),
            },
            "packages": {
                "aarch64-darwin": checks("tool"),
                "x86_64-linux": checks("tool"),
            },
            "devShells": {"aarch64-darwin": checks("default")},
            "formatter": {},
            "overlays": {},
            "nixosModules": {},
        },
    }
    for key, value in over.items():
        if key == "flake":
            fx["flake"].update(value)
        elif key == "config":
            fx["config"].update(value)
        else:
            fx[key] = value
    return fx


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        stub = bindir / "nix"
        stub.write_text(f"#!{PYTHON}\n{NIX_STUB}")
        stub.chmod(0o755)
        self.log = self.tmp / "nix.log"
        self.log.write_text("")
        self.fixture_path = self.tmp / "fixture.json"
        self.env = {
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "STUB_FIXTURE": str(self.fixture_path),
            "STUB_FLAKE": FLAKE,
            "HOME": str(self.tmp),
        }
        self.set_fixture()

    def set_fixture(self, **over):
        self.fixture_path.write_text(json.dumps(fixture(**over)))

    def drive(self, *argv, **env):
        return subprocess.run(
            [BASH, str(DRIVER), "--flake", FLAKE, *argv],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=120,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def built(self):
        return [a[-1].split("#", 1)[1] for a in self.calls() if a[0] == "build"]

    def evaluated_raw(self):
        return [
            a[-1].split("#", 1)[1]
            for a in self.calls()
            if a[0] == "eval" and "--raw" in a
        ]

    def assert_lock_preserved(self):
        for argv in self.calls():
            if argv[:2] == ["config", "show"]:
                continue
            self.assertIn("--no-update-lock-file", argv, argv)
            for bad in (
                "update",
                "lock",
                "--recreate-lock-file",
                "--update-input",
                "--commit-lock-file",
            ):
                self.assertNotIn(bad, argv, argv)


class Discovery(Harness):
    def test_every_configuration_kind_is_evaluated_sequentially(self):
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.evaluated_raw(),
            [
                'nixosConfigurations."hpp-1".config.system.build.toplevel.drvPath',
                'nixosConfigurations."terra".config.system.build.toplevel.drvPath',
                'darwinConfigurations."work".config.system.build.toplevel.drvPath',
                'homeConfigurations."penguin".activationPackage.drvPath',
            ],
        )
        self.assert_lock_preserved()

    def test_new_configuration_is_discovered_without_editing_the_driver(self):
        self.set_fixture(
            flake={
                "nixosConfigurations": {"hpp-1": {}, "newhost": {}},
                "homeConfigurations": {"penguin": {}, "other": {}},
            }
        )
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 0, r.stderr)
        raw = self.evaluated_raw()
        self.assertIn(
            'nixosConfigurations."newhost".config.system.build.toplevel.drvPath', raw
        )
        self.assertIn('homeConfigurations."other".activationPackage.drvPath', raw)
        self.assertIn("PASS     eval nixosConfigurations.newhost", r.stdout)

    def test_new_check_is_built_and_exclusions_are_honoured(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-linux"]["brand-new"] = {}
        self.set_fixture(
            flake=flake, config={"system": "x86_64-linux", "extra-platforms": ""}
        )
        r = self.drive("build-checks", "--exclude", "pre-commit")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            [
                'checks.x86_64-linux."brand-new"',
                'checks.x86_64-linux."doc-links"',
                'checks.x86_64-linux."vm-test"',
            ],
        )
        self.assert_lock_preserved()

    def test_eval_outputs_covers_every_system(self):
        r = self.drive("eval-outputs")
        self.assertEqual(r.returncode, 0, r.stderr)
        for label in (
            "eval checks.aarch64-darwin  (2 drvPaths)",
            "eval checks.x86_64-linux  (3 drvPaths)",
            "eval packages.x86_64-linux",
            "eval devShells.aarch64-darwin",
            "eval overlays",
            "eval nixosModules",
        ):
            self.assertIn(f"PASS     {label}", r.stdout)
        self.assertEqual(self.built(), [])
        self.assert_lock_preserved()


class Failures(Harness):
    def test_stale_lock_fails_and_stops_local(self):
        self.set_fixture(stale_lock=True)
        r = self.drive("lock")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     lock", r.stdout)
        self.log.write_text("")
        r = self.drive("local")
        self.assertEqual(r.returncode, 1)
        self.assertIn("NOT-RUN  eval, lint and check builds", r.stdout)
        self.assertNotIn("PASS", r.stdout)
        self.assertEqual(self.built(), [])
        self.assert_lock_preserved()

    def test_failed_eval_is_nonzero_but_other_configs_still_run(self):
        self.set_fixture(fail_eval=["nixosConfigurations.hpp-1"])
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     eval nixosConfigurations.hpp-1", r.stdout)
        self.assertIn("PASS     eval nixosConfigurations.terra", r.stdout)
        self.assertIn("PASS     eval homeConfigurations.penguin", r.stdout)

    def test_failed_enumeration_is_a_failure_not_an_empty_pass(self):
        self.set_fixture(fail_eval=["darwinConfigurations"])
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 1)
        self.assertIn(
            "FAIL     eval darwinConfigurations  (could not enumerate)", r.stdout
        )

    def test_failed_eval_outputs_and_bad_overlay_shape(self):
        self.set_fixture(fail_eval=["packages.x86_64-linux"], bad_shape=["overlays"])
        r = self.drive("eval-outputs")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     eval packages.x86_64-linux", r.stdout)
        self.assertIn("FAIL     eval overlays", r.stdout)
        self.assertIn("PASS     eval nixosModules", r.stdout)

    def test_failed_check_build_is_nonzero_and_the_rest_still_build(self):
        self.set_fixture(
            config={"system": "x86_64-linux", "extra-platforms": ""},
            fail_build=["checks.x86_64-linux.doc-links"],
        )
        r = self.drive("build-checks")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     build checks.x86_64-linux.doc-links", r.stdout)
        self.assertIn("PASS     build checks.x86_64-linux.vm-test", r.stdout)
        self.assertIn("FAILED", r.stderr)

    def test_failed_lint_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.pre-commit"])
        r = self.drive("lint")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     lint checks.aarch64-darwin.pre-commit", r.stdout)

    def test_failure_inside_local_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.doc-links"])
        r = self.drive("local")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL     build checks.aarch64-darwin.doc-links", r.stdout)


class Platforms(Harness):
    def test_non_native_system_is_refused_without_remote_builder(self):
        r = self.drive("build-checks", "--system", "x86_64-linux")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not native here", r.stderr)
        self.assertEqual(self.built(), [])
        r = self.drive("lint", "--system", "x86_64-linux")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.built(), [])

    def test_extra_platform_counts_as_native(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-darwin"] = checks("pre-commit")
        self.set_fixture(flake=flake)
        r = self.drive("lint", "--system", "x86_64-darwin")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.built(), ["checks.x86_64-darwin.pre-commit"])

    def test_remote_builder_must_declare_the_system(self):
        machines = self.tmp / "machines"
        machines.write_text("# comment\nssh://builder aarch64-linux - 2 1 kvm\n")
        self.set_fixture(config={"builders": f"@{machines}"})
        r = self.drive("build-checks", "--system", "x86_64-linux", "--remote-builder")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no configured builder", r.stderr)
        self.assertEqual(self.built(), [])

    def test_no_builders_configured_is_refused(self):
        r = self.drive("build-checks", "--system", "x86_64-linux", "--remote-builder")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.built(), [])

    def test_verified_remote_builder_builds_every_check(self):
        machines = self.tmp / "machines"
        machines.write_text(
            "ssh://builder x86_64-linux,i686-linux - 2 1 big-parallel,kvm,nixos-test\n"
        )
        for builders in (
            f"@{machines}",
            "ssh://other aarch64-linux; ssh://b x86_64-linux - 1",
        ):
            with self.subTest(builders=builders):
                self.log.write_text("")
                self.set_fixture(config={"builders": builders})
                r = self.drive(
                    "build-checks", "--system", "x86_64-linux", "--remote-builder"
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("remote builder", r.stdout)
                self.assertEqual(len(self.built()), 3)
                self.assert_lock_preserved()

    def test_local_on_darwin_defers_linux_checks_and_never_passes_them(self):
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            ["checks.aarch64-darwin.pre-commit", 'checks.aarch64-darwin."doc-links"'],
        )
        self.assertIn(
            "DEFERRED build checks.x86_64-linux  (3 checks evaluated, not built on aarch64-darwin: doc-links pre-commit vm-test)",
            r.stdout,
        )
        self.assertNotIn("PASS     build checks.x86_64-linux", r.stdout)
        self.assertIn("NOT built on this Mac", r.stdout)
        self.assertIn("PASS     lock", r.stdout)
        self.assertIn("PASS     eval homeConfigurations.penguin", r.stdout)
        self.assert_lock_preserved()

    def test_local_on_linux_builds_native_checks_and_defers_darwin(self):
        self.set_fixture(config={"system": "x86_64-linux", "extra-platforms": ""})
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            [
                "checks.x86_64-linux.pre-commit",
                'checks.x86_64-linux."doc-links"',
                'checks.x86_64-linux."vm-test"',
            ],
        )
        self.assertIn("DEFERRED build checks.aarch64-darwin", r.stdout)
        self.assertNotIn("NOT built on this Mac", r.stdout)


class Interface(Harness):
    def test_usage_errors(self):
        for argv in (
            [],
            ["bogus"],
            ["lock", "eval-configs"],
            ["local", "--system", "x86_64-linux"],
            ["eval-configs", "--remote-builder"],
            ["lint", "--exclude", "x"],
            ["build-checks", "--system"],
        ):
            with self.subTest(argv=argv):
                self.log.write_text("")
                r = self.drive(*argv)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertEqual(self.built(), [])

    def test_github_actions_groups_and_step_summary(self):
        summary = self.tmp / "summary.md"
        r = self.drive(
            "eval-configs", GITHUB_ACTIONS="true", GITHUB_STEP_SUMMARY=str(summary)
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("::group::eval nixosConfigurations.hpp-1", r.stdout)
        self.assertIn("::endgroup::", r.stdout)
        self.assertIn("PASS     eval darwinConfigurations.work", summary.read_text())

    def test_task_check_routes_through_the_driver(self):
        task = shutil.which("task")
        if task is None:
            self.skipTest("go-task not available")
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(DRIVER, repo / "scripts" / DRIVER.name)
        text = (REPO / "Taskfile.yaml").read_text()
        # Only the root Taskfile's own tasks are needed; drop the includes.
        head, _, rest = text.partition("includes:")
        rest = rest[rest.index("\ntasks:") :]
        (repo / "Taskfile.yaml").write_text(head + rest)
        env = {**self.env, "STUB_FLAKE": str(repo)}

        def run(*argv):
            self.log.write_text("")
            return subprocess.run(
                [task, "--silent", *argv],
                cwd=repo,
                env=env,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                timeout=120,
            )

        r = run("check")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DEFERRED build checks.x86_64-linux", r.stdout)
        meta = [a for a in self.calls() if a[:2] == ["flake", "metadata"]]
        self.assertEqual(len(meta), 1)
        self.assertEqual(os.path.realpath(meta[0][-1]), os.path.realpath(repo))
        self.set_fixture(stale_lock=True)
        self.assertNotEqual(run("check").returncode, 0)
        self.set_fixture(config={"builders": "ssh://b x86_64-linux"})
        r = run("check:linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.built()), 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
