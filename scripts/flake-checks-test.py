#!/usr/bin/env python3
"""Offline tests for scripts/flake-checks.sh (#1021).

`nix` is a logging stub on PATH that answers from a synthetic flake described
in JSON (configurations, per-system checks, injected failures, a stale lock,
the machine's system and remote builders, and per-call exit-status
overrides). Nothing is evaluated, built or fetched and no builder is
contacted. The Nix-language checks themselves (derivation identity, overlay
shape, system keys) are unit-tested by scripts/_flake-checks/tests.nix; here
the stub only reports what real nix would (a rejected value is a nonzero
exit).

Covered: discovery (a new configuration or check needs no driver edit),
lossless names (empty, newline and quote names fail, never vanish), required
non-empty sets, exit-status propagation for every nix call (a stub printing
the expected stdout but exiting 47 still fails), platform refusal, the
remote-builder gate (zero-slot entries, failed queries), DEFERRED/NOT-RUN
reporting, and that every nix call keeps --no-update-lock-file.

usage: flake-checks-test.py REPO_ROOT
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parent.parent
)
DRIVER = REPO / "scripts" / "flake-checks.sh"
LIB = REPO / "scripts" / "_flake-checks"
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
joined = " ".join(args)

for ov in fx.get("overrides", []):
    if all(m in joined for m in ov["match"]):
        sys.stdout.write(ov.get("stdout", ""))
        sys.exit(ov["status"])


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


def drv(name):
    return f"/nix/store/0000-{name or 'x'}.drv"


def is_bogus(node):
    return isinstance(node, dict) and node.get("bogus") is True


if args[:2] == ["config", "show"]:
    value = fx["config"].get(args[2])
    if value is None:
        sys.exit(1)
    print(value)
elif args[:2] == ["flake", "metadata"]:
    if fx.get("stale_lock"):
        print("error: cannot write modified lock file", file=sys.stderr)
        sys.exit(1)
elif args[:2] == ["flake", "prefetch"]:
    print(json.dumps({"storePath": "/nix/store/0000-source", "hash": "sha256-AAAA="}))
elif args[0] == "eval" and "--expr" in args:
    expr = args[args.index("--expr") + 1]
    assert "flake-checks:toplevel" in expr, expr
    assert 'getFlake "path:/nix/store/0000-source?narHash=sha256-AAAA="' in expr, expr
    if fx.get("toplevel_fail"):
        print("error: flake-checks: overlays.o must be a function", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(sorted(fx["flake"])))
elif args[0] == "eval":
    if fx.get("stale_lock"):
        sys.exit(1)
    installable = next(a for a in args[1:] if "#" in a)
    parts = attr_path(installable)
    failing("fail_eval", parts)
    apply = args[args.index("--apply") + 1]
    key = ".".join(parts)
    if apply == "builtins.attrNames":
        if key in fx.get("raw_names", {}):
            print(json.dumps(fx["raw_names"][key]))
        else:
            print(json.dumps(sorted(lookup(parts))))
    elif "flake-checks:derivations" in apply:
        single = "single = true;" in apply
        # a configuration toplevel: the fixture models only the name
        node = lookup(parts[:2] if "Configurations" in parts[0] else parts)
        if single:
            if is_bogus(node):
                sys.exit(1)
            print(json.dumps({"": drv(parts[1])}))
        else:
            if any(is_bogus(v) for v in node.values()):
                print("error: flake-checks: drvPath is not a store derivation path", file=sys.stderr)
                sys.exit(1)
            names = fx.get("raw_names", {}).get(key, list(node))
            print(json.dumps({n: drv(n) for n in names}))
    else:
        sys.exit(f"stub nix: unexpected eval {args}")
elif args[0] == "build":
    installable = next(a for a in args[1:] if "#" in a)
    if not installable.endswith("^*"):
        sys.exit(f"stub nix: build without ^* {installable}")
    parts = attr_path(installable[:-2])
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


LINUX = {"system": "x86_64-linux", "extra-platforms": ""}


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
            "TMPDIR": str(self.tmp),
        }
        self.set_fixture()

    def set_fixture(self, **over):
        self.fixture_path.write_text(json.dumps(fixture(**over)))

    def drive(self, *argv, **env):
        self.log.write_text("")
        return subprocess.run(
            [BASH, str(DRIVER), "--flake", FLAKE, *argv],
            check=False,
            env={**self.env, **env},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=120,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def built(self):
        return [
            next(a for a in c if "#" in a).split("#", 1)[1]
            for c in self.calls()
            if c[0] == "build"
        ]

    def evaluated_configs(self):
        out = []
        for c in self.calls():
            if c[0] == "eval" and "--apply" in c:
                inst = next(a for a in c if "#" in a).split("#", 1)[1]
                if "Configurations." in inst:
                    out.append(inst)
        return out

    def assert_lock_preserved(self):
        for argv in self.calls():
            if argv[:2] == ["config", "show"]:
                continue
            self.assertIn("--no-update-lock-file", argv, argv)
            for bad in ("update", "lock", "--recreate-lock-file", "--commit-lock-file"):
                self.assertNotIn(bad, argv, argv)

    def assert_failed(self, r, *lines):
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        for line in lines:
            self.assertIn(line, r.stdout)


class Discovery(Harness):
    def test_every_configuration_kind_is_evaluated_as_a_derivation(self):
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.evaluated_configs(),
            [
                'nixosConfigurations."hpp-1".config.system.build.toplevel',
                'nixosConfigurations."terra".config.system.build.toplevel',
                'darwinConfigurations."work".config.system.build.toplevel',
                'homeConfigurations."penguin".activationPackage',
            ],
        )
        for c in self.calls():
            if c[0] == "eval" and "Configurations." in " ".join(c):
                apply = c[c.index("--apply") + 1]
                if apply != "builtins.attrNames":
                    self.assertIn("flake-checks:derivations", apply)
                    self.assertIn("single = true;", apply)
        self.assertIn("/nix/store/0000-hpp-1.drv", r.stdout)
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
        configs = self.evaluated_configs()
        self.assertIn(
            'nixosConfigurations."newhost".config.system.build.toplevel', configs
        )
        self.assertIn('homeConfigurations."other".activationPackage', configs)
        self.assertIn("PASS     eval nixosConfigurations.newhost", r.stdout)

    def test_new_check_is_built_with_all_outputs_and_exclusions_honoured(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-linux"]["brand-new"] = {}
        flake["checks"]["x86_64-linux"]["dotted.name"] = {}
        self.set_fixture(flake=flake, config=LINUX)
        r = self.drive("build-checks", "--exclude", "pre-commit")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            [
                'checks.x86_64-linux."brand-new"^*',
                'checks.x86_64-linux."doc-links"^*',
                'checks.x86_64-linux."dotted.name"^*',
                'checks.x86_64-linux."vm-test"^*',
            ],
        )
        self.assert_lock_preserved()

    def test_eval_outputs_forces_top_level_and_checks_every_system(self):
        r = self.drive("eval-outputs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PASS     eval top-level outputs", r.stdout)
        for label in (
            "eval checks.aarch64-darwin  (2 derivations)",
            "eval checks.x86_64-linux  (3 derivations)",
            "eval packages.x86_64-linux  (1 derivations)",
            "eval devShells.aarch64-darwin  (1 derivations)",
        ):
            self.assertIn(f"PASS     {label}", r.stdout)
        applies = [
            c[c.index("--apply") + 1]
            for c in self.calls()
            if c[0] == "eval" and "--apply" in c
        ]
        self.assertTrue(
            all(
                "flake-checks:derivations" in a or a == "builtins.attrNames"
                for a in applies
            )
        )
        self.assertEqual(self.built(), [])
        self.assert_lock_preserved()

    def test_lint_requests_all_outputs(self):
        r = self.drive("lint")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.built(), ["checks.aarch64-darwin.pre-commit^*"])


class Names(Harness):
    def test_empty_name_is_a_failure_and_builds_nothing(self):
        self.set_fixture(config=LINUX, raw_names={"checks.x86_64-linux": [""]})
        r = self.drive("build-checks")
        self.assert_failed(
            r, 'FAIL     build checks.x86_64-linux  (unsupported attribute name "")'
        )
        self.assertEqual(self.built(), [])

    def test_newline_and_quote_names_fail_and_are_reported_escaped(self):
        self.set_fixture(
            config=LINUX,
            raw_names={"checks.x86_64-linux": ["a\nb", 'q"uote', "doc-links"]},
        )
        r = self.drive("build-checks")
        self.assert_failed(
            r,
            'unsupported attribute name "a\\nb"',
            'unsupported attribute name "q\\"uote"',
            "PASS     build checks.x86_64-linux.doc-links",
        )
        self.assertEqual(self.built(), ['checks.x86_64-linux."doc-links"^*'])

    def test_unsupported_configuration_name_fails(self):
        self.set_fixture(raw_names={"nixosConfigurations": ["hpp-1", "bad name"]})
        r = self.drive("eval-configs")
        self.assert_failed(
            r,
            'FAIL     eval nixosConfigurations  (unsupported attribute name "bad name")',
            "PASS     eval nixosConfigurations.hpp-1",
        )

    def test_unsupported_system_name_fails(self):
        self.set_fixture(raw_names={"packages": ["x86_64-linux", "Bad"]})
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval packages  (invalid system name Bad)")


class RequiredSets(Harness):
    def test_empty_configuration_kind_fails(self):
        for kind in (
            "nixosConfigurations",
            "darwinConfigurations",
            "homeConfigurations",
        ):
            with self.subTest(kind=kind):
                self.set_fixture(flake={kind: {}})
                r = self.drive("eval-configs")
                self.assert_failed(
                    r,
                    f"FAIL     eval {kind}  (no configurations; every configuration kind must be non-empty)",
                )

    def test_missing_configuration_kind_fails(self):
        flake = fixture()["flake"]
        del flake["darwinConfigurations"]
        self.fixture_path.write_text(json.dumps({**fixture(), "flake": flake}))
        r = self.drive("eval-configs")
        self.assert_failed(
            r, "FAIL     eval darwinConfigurations  (could not enumerate)"
        )

    def test_selected_system_without_checks_fails(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-linux"] = {}
        self.set_fixture(flake=flake, config=LINUX)
        r = self.drive("build-checks")
        self.assert_failed(r, "FAIL     build checks.x86_64-linux  (no checks")
        self.assertEqual(self.built(), [])

    def test_nothing_left_after_exclusions_fails(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-linux"] = checks("pre-commit")
        self.set_fixture(flake=flake, config=LINUX)
        r = self.drive("build-checks", "--exclude", "pre-commit")
        self.assert_failed(r, "nothing left to build after exclusions")


class ExitStatus(Harness):
    """A nix call that prints plausible output but exits nonzero must fail."""

    def override(self, match, stdout, status=47, **over):
        self.set_fixture(
            overrides=[{"match": match, "stdout": stdout, "status": status}], **over
        )

    def test_top_level_eval_exit_47_with_valid_output_fails(self):
        self.override(["flake-checks:toplevel"], '["checks"]')
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval top-level outputs")

    def test_top_level_rejection_fails(self):
        self.set_fixture(toplevel_fail=True)
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval top-level outputs")

    def test_prefetch_failure_fails(self):
        self.override(
            ["flake", "prefetch"],
            '{"storePath":"/nix/store/0000-source","hash":"sha256-AAAA="}',
        )
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval top-level outputs")
        self.assertFalse(any("--expr" in c for c in self.calls()))

    def test_attr_names_exit_47_fails(self):
        self.override(["nixosConfigurations", "builtins.attrNames"], '["hpp-1"]')
        r = self.drive("eval-configs")
        self.assert_failed(
            r, "FAIL     eval nixosConfigurations  (could not enumerate)"
        )

    def test_config_eval_exit_47_fails(self):
        self.override(
            ['"hpp-1"', "flake-checks:derivations"], '{"":"/nix/store/0000-x.drv"}'
        )
        r = self.drive("eval-configs")
        self.assert_failed(r, "FAIL     eval nixosConfigurations.hpp-1")

    def test_derivation_eval_exit_47_fails(self):
        self.override(
            ["checks.x86_64-linux", "flake-checks:derivations"],
            '{"a":"/nix/store/0000-a.drv"}',
        )
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval checks.x86_64-linux")

    def test_build_exit_47_fails(self):
        self.override(['"doc-links"^*'], "", config=LINUX)
        r = self.drive("build-checks")
        self.assert_failed(r, "FAIL     build checks.x86_64-linux.doc-links")

    def test_lock_exit_47_fails(self):
        self.override(["flake", "metadata"], "{}")
        r = self.drive("lock")
        self.assert_failed(r, "FAIL     lock")

    def test_system_query_failure_refuses(self):
        self.override(["config", "show", "system"], "aarch64-darwin\n", status=1)
        r = self.drive("lint")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.built(), [])

    def test_extra_platforms_query_failure_refuses(self):
        self.override(["config", "show", "extra-platforms"], "x86_64-darwin\n", 1)
        r = self.drive("lint", "--system", "x86_64-darwin")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.built(), [])


class Failures(Harness):
    def test_stale_lock_fails_and_stops_local(self):
        self.set_fixture(stale_lock=True)
        r = self.drive("lock")
        self.assert_failed(r, "FAIL     lock")
        r = self.drive("local")
        self.assert_failed(r, "NOT-RUN  eval, lint and check builds")
        self.assertNotIn("PASS", r.stdout)
        self.assertEqual(self.built(), [])
        self.assert_lock_preserved()

    def test_failed_eval_is_nonzero_but_other_configs_still_run(self):
        self.set_fixture(fail_eval=["nixosConfigurations.hpp-1"])
        r = self.drive("eval-configs")
        self.assert_failed(
            r,
            "FAIL     eval nixosConfigurations.hpp-1",
            "PASS     eval nixosConfigurations.terra",
            "PASS     eval homeConfigurations.penguin",
        )

    def test_bogus_derivation_fails_and_is_neither_built_nor_deferred(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-linux"]["fake"] = {"bogus": True}
        self.set_fixture(flake=flake)
        r = self.drive("local")
        self.assert_failed(
            r,
            "FAIL     eval checks.x86_64-linux",
            "NOT-RUN  build checks.x86_64-linux  (evaluation failed, see above)",
            "x86_64-linux checks FAILED evaluation",
        )
        self.assertNotIn("DEFERRED build checks.x86_64-linux", r.stdout)
        self.assertNotIn("x86_64-linux checks were evaluated", r.stdout)

    def test_failed_check_build_is_nonzero_and_the_rest_still_build(self):
        self.set_fixture(config=LINUX, fail_build=["checks.x86_64-linux.doc-links"])
        r = self.drive("build-checks")
        self.assert_failed(
            r,
            "FAIL     build checks.x86_64-linux.doc-links",
            "PASS     build checks.x86_64-linux.vm-test",
        )
        self.assertIn("FAILED", r.stderr)

    def test_failed_native_eval_skips_builds(self):
        self.set_fixture(config=LINUX, fail_eval=["checks.x86_64-linux"])
        r = self.drive("build-checks")
        self.assert_failed(
            r,
            "FAIL     eval checks.x86_64-linux",
            "NOT-RUN  build checks.x86_64-linux  (evaluation failed)",
        )
        self.assertEqual(self.built(), [])

    def test_failed_lint_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.pre-commit"])
        r = self.drive("lint")
        self.assert_failed(r, "FAIL     lint checks.aarch64-darwin.pre-commit")

    def test_failure_inside_local_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.doc-links"])
        r = self.drive("local")
        self.assert_failed(r, "FAIL     build checks.aarch64-darwin.doc-links")


class Platforms(Harness):
    def machines(self, text):
        path = self.tmp / "machines"
        path.write_text(text)
        return f"@{path}"

    def test_non_native_system_is_refused_without_remote_builder(self):
        for mode in ("build-checks", "lint"):
            with self.subTest(mode=mode):
                r = self.drive(mode, "--system", "x86_64-linux")
                self.assertEqual(r.returncode, 2)
                self.assertIn("not native here", r.stderr)
                self.assertEqual(self.built(), [])

    def test_extra_platform_counts_as_native(self):
        flake = fixture()["flake"]
        flake["checks"]["x86_64-darwin"] = checks("pre-commit")
        self.set_fixture(flake=flake)
        r = self.drive("lint", "--system", "x86_64-darwin")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.built(), ["checks.x86_64-darwin.pre-commit^*"])

    def refused(self, builders, why):
        self.set_fixture(config={"builders": builders})
        r = self.drive("build-checks", "--system", "x86_64-linux", "--remote-builder")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn(why, r.stderr)
        self.assertEqual(self.built(), [])

    def test_builder_must_declare_the_system(self):
        self.refused(
            self.machines("# comment\nssh://b aarch64-linux - 2 1 kvm\n"),
            "no configured builder declares x86_64-linux",
        )

    def test_zero_slot_builder_is_unusable(self):
        self.refused(
            self.machines("ssh://b x86_64-linux - 0 1 kvm\n"),
            "zero-slot or malformed entries ignored: ssh://b",
        )

    def test_malformed_slot_count_is_unusable(self):
        self.refused("ssh://b x86_64-linux - lots", "ignored: ssh://b")

    def test_no_builders_configured_is_refused(self):
        self.refused("", "no configured builder declares x86_64-linux")

    def test_failed_builders_query_refuses_even_with_matching_output(self):
        self.set_fixture(
            overrides=[
                {
                    "match": ["config", "show", "builders"],
                    "stdout": "ssh://b x86_64-linux - 4\n",
                    "status": 1,
                }
            ]
        )
        r = self.drive("build-checks", "--system", "x86_64-linux", "--remote-builder")
        self.assertEqual(r.returncode, 2)
        self.assertIn("`nix config show builders` failed", r.stderr)
        self.assertEqual(self.built(), [])

    def test_unreadable_builders_file_is_refused(self):
        self.refused(f"@{self.tmp}/missing", "no configured builder declares")

    def test_declared_builder_allows_the_build_with_honest_wording(self):
        cases = (
            self.machines("ssh://b x86_64-linux,i686-linux - 2 1 big-parallel,kvm\n"),
            "ssh://other aarch64-linux; ssh://b x86_64-linux - 1",
            "ssh://b x86_64-linux",  # maxJobs defaults to 1
            "ssh://b x86_64-linux - -",
        )
        for builders in cases:
            with self.subTest(builders=builders):
                self.set_fixture(config={"builders": builders})
                r = self.drive(
                    "build-checks", "--system", "x86_64-linux", "--remote-builder"
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("declares it on: ssh://b", r.stdout)
                self.assertIn("reachability is not probed", r.stdout)
                self.assertIn("not that a builder ran it", r.stdout)
                self.assertNotIn("building through", r.stdout)
                self.assertEqual(len(self.built()), 3)
                self.assert_lock_preserved()

    def test_local_on_darwin_defers_non_native_checks_and_never_passes_them(self):
        flake = fixture()["flake"]
        flake["checks"]["aarch64-linux"] = checks("pre-commit")
        self.set_fixture(flake=flake)
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            [
                "checks.aarch64-darwin.pre-commit^*",
                'checks.aarch64-darwin."doc-links"^*',
            ],
        )
        self.assertIn(
            "DEFERRED build checks.x86_64-linux  (3 checks evaluated, not built on aarch64-darwin: doc-links pre-commit vm-test)",
            r.stdout,
        )
        self.assertIn("DEFERRED build checks.aarch64-linux", r.stdout)
        self.assertNotIn("PASS     build checks.x86_64-linux", r.stdout)
        self.assertIn(
            "x86_64-linux checks were evaluated but NOT built here; build them with `task check:linux`",
            r.stdout,
        )
        self.assertIn("aarch64-linux checks were evaluated but NOT built", r.stdout)
        self.assertIn("they remain deferred", r.stdout)
        self.assertIn("PASS     lock", r.stdout)
        self.assertIn("PASS     eval top-level outputs", r.stdout)
        self.assertIn("PASS     eval homeConfigurations.penguin", r.stdout)
        self.assert_lock_preserved()

    def test_local_reuses_native_evaluation(self):
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stderr)
        native_evals = [
            c
            for c in self.calls()
            if c[0] == "eval" and any(a.endswith("#checks.aarch64-darwin") for a in c)
        ]
        self.assertEqual(len(native_evals), 1)

    def test_local_on_linux_builds_native_checks_and_defers_darwin(self):
        self.set_fixture(config=LINUX)
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.built(),
            [
                "checks.x86_64-linux.pre-commit^*",
                'checks.x86_64-linux."doc-links"^*',
                'checks.x86_64-linux."vm-test"^*',
            ],
        )
        self.assertIn("DEFERRED build checks.aarch64-darwin", r.stdout)
        self.assertNotIn("task check:linux", r.stdout)


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
            ["build-checks", "--system", 'x86_64-linux"; x'],
        ):
            with self.subTest(argv=argv):
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

    def test_expressions_are_tracked_files_with_markers(self):
        self.assertIn("flake-checks:derivations", (LIB / "derivations.nix").read_text())
        self.assertIn("flake-checks:toplevel", (LIB / "toplevel.nix").read_text())

    def test_task_check_routes_through_the_driver(self):
        task = shutil.which("task")
        if task is None:
            self.skipTest("go-task not available")
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(DRIVER, repo / "scripts" / DRIVER.name)
        shutil.copytree(LIB, repo / "scripts" / LIB.name)
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
                check=False,
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
