#!/usr/bin/env python3
"""Offline tests for scripts/flake-checks.sh (#1021).

Two layers:

- Stub tests: `nix` is a logging stub on PATH answering from a synthetic flake
  described in JSON (configurations, checks, injected failures, a stale lock,
  the machine's system and builders, per-call exit-status/stdout overrides).
  Nothing is evaluated, built or fetched; no builder is contacted. They cover
  discovery, the one name choke point, required non-empty sets, exit-status
  and decode-failure propagation, the remote-builder gate and Nix's builders
  syntax, DEFERRED/NOT-RUN reporting, flake-reference identity, and that every
  nix call keeps --no-update-lock-file.
- Real-nix tests (when FLAKE_CHECKS_REAL_NIX names a directory holding a real
  `nix`): the driver's eval-outputs stage runs genuine
  `nix flake check --no-build` against small synthetic flakes in a private
  store, showing the gate keeps nix's own verdicts (derivation identity,
  overlay and app shape) and evaluates the flake reference it was given
  (`?dir=`, git metadata such as self.rev).

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
# The Nix build sandbox has no /usr/bin/env: run the driver with this bash.
BASH = os.path.realpath(shutil.which("bash") or "/bin/bash")
PYTHON = os.path.realpath(sys.executable)
FLAKE = "/synthetic/flake"
REAL_NIX = os.environ.get("FLAKE_CHECKS_REAL_NIX")

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


def same_flake(flake):
    want = os.environ["STUB_FLAKE"]
    if ":" in want or "?" in want:
        return flake == want
    return os.path.realpath(flake) == os.path.realpath(want)


def attr_path(installable):
    flake, _, path = installable.partition("#")
    if not same_flake(flake):
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
    if not same_flake(args[2]):
        sys.exit(f"stub nix: unexpected flake {args[2]!r}")
    if fx.get("stale_lock"):
        print("error: cannot write modified lock file", file=sys.stderr)
        sys.exit(1)
elif args[:2] == ["flake", "check"]:
    assert "--no-build" in args and "--all-systems" in args, args
    if not same_flake(next(a for a in args[2:] if not a.startswith("--"))):
        sys.exit("stub nix: unexpected flake")
    if fx.get("flake_check_fail"):
        print("error: flake attribute 'checks.x.y' is not a derivation", file=sys.stderr)
        sys.exit(1)
elif args[0] == "eval":
    if fx.get("stale_lock"):
        sys.exit(1)
    installable = next(a for a in args[1:] if "#" in a)
    parts = attr_path(installable)
    failing("fail_eval", parts)
    key = ".".join(parts)
    if "--raw" in args:
        assert parts[-1] == "drvPath", parts
        lookup(parts[:2])
        print(f"/nix/store/0000-{parts[1]}.drv", end="")
    elif args[args.index("--apply") + 1] == "builtins.attrNames":
        if key in fx.get("raw_json", {}):
            sys.stdout.write(fx["raw_json"][key])
        elif key in fx.get("raw_names", {}):
            print(json.dumps(fx["raw_names"][key]))
        else:
            print(json.dumps(sorted(lookup(parts))))
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
    flake = FLAKE

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
            "STUB_FLAKE": self.flake,
            "HOME": str(self.tmp),
            "TMPDIR": str(self.tmp),
        }
        self.set_fixture()

    def set_fixture(self, **over):
        self.fixture_path.write_text(json.dumps(fixture(**over)))

    def drive(self, *argv, **env):
        self.log.write_text("")
        return subprocess.run(
            [BASH, str(DRIVER), "--flake", self.flake, *argv],
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
        return [
            next(a for a in c if "#" in a).split("#", 1)[1]
            for c in self.calls()
            if c[0] == "eval" and "--raw" in c
        ]

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
    def test_every_configuration_kind_is_evaluated(self):
        r = self.drive("eval-configs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.evaluated_configs(),
            [
                'nixosConfigurations."hpp-1".config.system.build.toplevel.drvPath',
                'nixosConfigurations."terra".config.system.build.toplevel.drvPath',
                'darwinConfigurations."work".config.system.build.toplevel.drvPath',
                'homeConfigurations."penguin".activationPackage.drvPath',
            ],
        )
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
            'nixosConfigurations."newhost".config.system.build.toplevel.drvPath',
            configs,
        )
        self.assertIn('homeConfigurations."other".activationPackage.drvPath', configs)
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

    def test_eval_outputs_is_nix_flake_check_no_build_all_systems(self):
        r = self.drive("eval-outputs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.calls(),
            [
                [
                    "flake",
                    "check",
                    "--no-build",
                    "--all-systems",
                    FLAKE,
                    "--no-update-lock-file",
                ]
            ],
        )
        self.assertIn("PASS     eval outputs", r.stdout)

    def test_lint_requests_all_outputs(self):
        r = self.drive("lint")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.built(), ["checks.aarch64-darwin.pre-commit^*"])


class Identity(Harness):
    """Every stage hands nix the exact reference it was given."""

    flake = "git+file:///synthetic/repo?dir=sub&ref=main"

    def test_every_nix_call_uses_the_given_reference_verbatim(self):
        r = self.drive("local")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        refs = set()
        for c in self.calls():
            if c[:2] == ["config", "show"]:
                continue
            for a in c:
                if a.startswith("git+file:"):
                    refs.add(a.split("#", 1)[0])
        self.assertEqual(refs, {self.flake})
        kinds = {tuple(c[:2]) for c in self.calls()}
        self.assertIn(("flake", "metadata"), kinds)
        self.assertIn(("flake", "check"), kinds)
        self.assertFalse(any("prefetch" in c or "--expr" in c for c in self.calls()))


class Names(Harness):
    def test_empty_name_is_a_failure_and_builds_nothing(self):
        self.set_fixture(config=LINUX, raw_names={"checks.x86_64-linux": [""]})
        r = self.drive("build-checks")
        self.assert_failed(
            r, 'FAIL     build checks.x86_64-linux  (unsupported attribute name "")'
        )
        self.assertEqual(self.built(), [])

    def test_trailing_newline_name_is_never_rewritten(self):
        self.set_fixture(
            config=LINUX, raw_names={"checks.x86_64-linux": ["vm-test\n", "doc-links"]}
        )
        r = self.drive("build-checks")
        self.assert_failed(r, 'unsupported attribute name "vm-test\\n"')
        self.assertNotIn("PASS", r.stdout)
        self.assertEqual(self.built(), [])

    def test_newline_quote_space_and_unicode_names_fail_escaped(self):
        self.set_fixture(
            raw_names={
                "nixosConfigurations": ["a\nb", 'q"uote', "sp ace", "café", "ok"]
            },
            flake={"nixosConfigurations": {"ok": {}}},
        )
        r = self.drive("eval-configs")
        self.assert_failed(
            r,
            'unsupported attribute name "a\\nb"',
            'unsupported attribute name "q\\"uote"',
            'unsupported attribute name "sp ace"',
            'unsupported attribute name "café"',
            "PASS     eval nixosConfigurations.ok",
        )

    def test_non_string_name_fails(self):
        self.set_fixture(raw_json={"nixosConfigurations": "[1]\n"})
        r = self.drive("eval-configs")
        self.assert_failed(r, "unsupported attribute name 1")

    def test_deferred_names_pass_the_same_choke_point(self):
        for raw in ([""], ["a\nb"], ["vm-test\n"]):
            with self.subTest(raw=raw):
                self.set_fixture(raw_names={"checks.x86_64-linux": raw})
                r = self.drive("local")
                self.assert_failed(
                    r,
                    "unsupported attribute name",
                    "NOT-RUN  build checks.x86_64-linux  (check names could not be enumerated and validated)",
                )
                self.assertNotIn("DEFERRED build checks.x86_64-linux", r.stdout)
                self.assertNotIn("x86_64-linux checks were evaluated", r.stdout)

    def test_invalid_system_name_fails(self):
        self.set_fixture(raw_names={"checks": ["aarch64-darwin", "Bad-System"]})
        r = self.drive("local")
        self.assert_failed(r, "invalid system name Bad-System")


class Decoding(Harness):
    """A name list that cannot be decoded never yields PASS or DEFERRED."""

    def test_unparseable_config_names_fail(self):
        self.set_fixture(raw_json={"nixosConfigurations": "[\n"})
        r = self.drive("eval-configs")
        self.assert_failed(
            r, "FAIL     eval nixosConfigurations  (could not decode attribute names)"
        )
        self.assertNotIn("PASS     eval nixosConfigurations", r.stdout)

    def test_unparseable_check_names_fail_build(self):
        self.set_fixture(config=LINUX, raw_json={"checks.x86_64-linux": "{oops"})
        r = self.drive("build-checks")
        self.assert_failed(
            r, "could not decode attribute names", "NOT-RUN  build checks.x86_64-linux"
        )
        self.assertEqual(self.built(), [])

    def test_unparseable_deferred_names_are_not_deferred(self):
        self.set_fixture(raw_json={"checks.x86_64-linux": "not json"})
        r = self.drive("local")
        self.assert_failed(r, "could not decode attribute names")
        self.assertNotIn("DEFERRED build checks.x86_64-linux", r.stdout)

    def test_unparseable_system_list_fails(self):
        self.set_fixture(raw_json={"checks": "]"})
        r = self.drive("local")
        self.assert_failed(r, "FAIL     enumerate checks systems  (could not decode")
        self.assertNotIn("DEFERRED", r.stdout)

    def test_object_instead_of_list_fails(self):
        self.set_fixture(raw_json={"homeConfigurations": '{"penguin": 1}'})
        r = self.drive("eval-configs")
        self.assert_failed(r, "FAIL     eval homeConfigurations  (could not decode")


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
                    f"FAIL     eval {kind}  (no usable configurations; every configuration kind must be non-empty)",
                )

    def test_kind_with_only_unsupported_names_fails_as_empty(self):
        self.set_fixture(raw_names={"darwinConfigurations": [""]})
        r = self.drive("eval-configs")
        self.assert_failed(r, "FAIL     eval darwinConfigurations  (no usable")

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

    def test_flake_check_exit_47_fails(self):
        self.override(["flake", "check"], "")
        r = self.drive("eval-outputs")
        self.assert_failed(r, "FAIL     eval outputs")

    def test_attr_names_exit_47_fails(self):
        self.override(["nixosConfigurations", "builtins.attrNames"], '["hpp-1"]')
        r = self.drive("eval-configs")
        self.assert_failed(
            r, "FAIL     eval nixosConfigurations  (could not enumerate)"
        )

    def test_config_eval_exit_47_fails(self):
        self.override(['"hpp-1"', "--raw"], "/nix/store/0000-x.drv")
        r = self.drive("eval-configs")
        self.assert_failed(r, "FAIL     eval nixosConfigurations.hpp-1")

    def test_check_names_exit_47_fails(self):
        self.override(["checks.x86_64-linux", "attrNames"], '["a"]', config=LINUX)
        r = self.drive("build-checks")
        self.assert_failed(r, "NOT-RUN  build checks.x86_64-linux")
        self.assertEqual(self.built(), [])

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

    def test_failed_flake_check_makes_non_native_not_run_not_deferred(self):
        self.set_fixture(flake_check_fail=True)
        r = self.drive("local")
        self.assert_failed(
            r,
            "FAIL     eval outputs",
            "NOT-RUN  build checks.x86_64-linux  (nix flake check --no-build failed, see above)",
            "x86_64-linux checks FAILED evaluation",
        )
        self.assertNotIn("DEFERRED", r.stdout)
        self.assertNotIn("checks were evaluated", r.stdout)

    def test_failed_check_build_is_nonzero_and_the_rest_still_build(self):
        self.set_fixture(config=LINUX, fail_build=["checks.x86_64-linux.doc-links"])
        r = self.drive("build-checks")
        self.assert_failed(
            r,
            "FAIL     build checks.x86_64-linux.doc-links",
            "PASS     build checks.x86_64-linux.vm-test",
        )
        self.assertIn("FAILED", r.stderr)

    def test_failed_lint_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.pre-commit"])
        r = self.drive("lint")
        self.assert_failed(r, "FAIL     lint checks.aarch64-darwin.pre-commit")

    def test_failure_inside_local_is_nonzero(self):
        self.set_fixture(fail_build=["checks.aarch64-darwin.doc-links"])
        r = self.drive("local")
        self.assert_failed(r, "FAIL     build checks.aarch64-darwin.doc-links")


class Platforms(Harness):
    def machines(self, text, name="machines"):
        path = self.tmp / name
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

    def test_comment_hides_everything_after_it_including_semicolons(self):
        line = "ssh://arm aarch64-linux - 2 # spare; ssh://disabled x86_64-linux - 3"
        for builders in (
            line,
            self.machines(line + "\n"),
            "# ssh://off x86_64-linux - 4\nssh://arm aarch64-linux",
        ):
            with self.subTest(builders=builders):
                self.refused(builders, "no configured builder declares x86_64-linux")

    def test_semicolons_and_newlines_both_separate_entries(self):
        nested = self.machines("ssh://b x86_64-linux - 3\n", "nested")
        for builders in (
            "ssh://arm aarch64-linux - 2; ssh://b x86_64-linux - 3 # note",
            "ssh://arm aarch64-linux\n  ssh://b x86_64-linux - 3  ",
            self.machines(nested + " ; ssh://arm aarch64-linux\n"),
        ):
            with self.subTest(builders=builders):
                self.set_fixture(config={"builders": builders})
                r = self.drive(
                    "build-checks", "--system", "x86_64-linux", "--remote-builder"
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("declares it on: ssh://b (3 jobs)", r.stdout)

    def test_builder_must_declare_the_system(self):
        self.refused(
            self.machines("# comment\nssh://b aarch64-linux - 2 1 kvm\n"),
            "no configured builder declares x86_64-linux",
        )

    def test_default_systems_field_is_the_local_system_only(self):
        self.refused("ssh://b - - 4", "no configured builder declares x86_64-linux")

    def test_zero_slot_builder_is_unusable(self):
        self.refused(
            self.machines("ssh://b x86_64-linux - 0 1 kvm\n"),
            "zero-slot or malformed entries ignored: ssh://b",
        )

    def test_malformed_slot_count_is_unusable(self):
        self.refused("ssh://b x86_64-linux - lots", "ignored: ssh://b")

    def test_no_builders_configured_is_refused(self):
        self.refused("", "no configured builder declares x86_64-linux")

    def test_missing_builders_file_is_skipped_like_nix(self):
        self.refused(f"@{self.tmp}/missing", "no configured builder declares")

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
            "DEFERRED build checks.x86_64-linux  (3 checks evaluated by nix flake check --no-build, not built on aarch64-darwin: doc-links pre-commit vm-test)",
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
        self.assertIn("PASS     eval outputs", r.stdout)
        self.assertIn("PASS     eval homeConfigurations.penguin", r.stdout)
        self.assert_lock_preserved()

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
        self.assertEqual(os.path.realpath(meta[0][2]), os.path.realpath(repo))
        self.set_fixture(stale_lock=True)
        self.assertNotEqual(run("check").returncode, 0)
        self.set_fixture(config={"builders": "ssh://b x86_64-linux"})
        r = run("check:linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.built()), 3)


LOCK = '{"nodes":{"root":{}},"root":"root","version":7}'


@unittest.skipUnless(REAL_NIX, "FLAKE_CHECKS_REAL_NIX not set")
class RealNix(unittest.TestCase):
    """eval-outputs keeps genuine `nix flake check --no-build` verdicts."""

    def setUp(self):
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp()))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "conf").mkdir()
        self.env = {
            "PATH": f"{REAL_NIX}:{os.environ['PATH']}",
            "HOME": str(self.tmp),
            "TMPDIR": str(self.tmp),
            "XDG_CONFIG_HOME": str(self.tmp / "conf"),
            "XDG_CACHE_HOME": str(self.tmp / "cache"),
            "NIX_CONF_DIR": str(self.tmp / "conf"),
            "NIX_CONFIG": "\n".join(
                [
                    f"store = {self.tmp / 'store'}",
                    "experimental-features = nix-command flakes",
                    "substituters =",
                    "warn-dirty = false",
                ]
            ),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        self.system = subprocess.run(
            ["nix", "config", "show", "system"],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def flake(self, name, outputs, subdir=None):
        root = self.tmp / name
        where = root / subdir if subdir else root
        where.mkdir(parents=True)
        drv = (
            f'd = derivation {{ name = "x"; system = "{self.system}";'
            ' builder = "/bin/sh"; };'
        )
        (where / "flake.nix").write_text(
            "{ outputs = { self }: let " + drv + " in " + outputs + "; }\n"
        )
        (where / "flake.lock").write_text(LOCK)
        return root

    def eval_outputs(self, ref):
        r = subprocess.run(
            [BASH, str(DRIVER), "--flake", ref, "eval-outputs"],
            check=False,
            env=self.env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=300,
        )
        self.assertIn(r.returncode, (0, 1), r.stdout + r.stderr)
        return r

    def verdict(self, outputs, name="f"):
        root = self.flake(name, outputs)
        return self.eval_outputs(f"path:{root}").returncode

    def test_well_formed_flake_passes(self):
        s = self.system
        r = self.verdict(
            "{ checks." + s + ".a = d; overlays.o = final: prev: { };"
            " apps." + s + '.a = { type = "app"; program = "${d}/bin/x";'
            ' meta.description = "x"; }; }'
        )
        self.assertEqual(r, 0)

    def test_not_a_store_path_drv_with_unrelated_context_fails(self):
        r = self.verdict(
            "{ checks." + self.system + '.a = { type = "derivation"; name = "x";'
            ' outPath = d.outPath; drvPath = "/nix/store/not-a-store-path.drv"'
            " + builtins.substring 0 0 d.outPath; }; }"
        )
        self.assertEqual(r, 1)

    def test_overlay_named_ignored_fails(self):
        self.assertEqual(self.verdict("{ overlays.o = ignored: prev: { }; }"), 1)

    def test_overlay_needing_a_real_final_passes(self):
        self.assertEqual(
            self.verdict("{ overlays.o = final: assert final ? x; prev: { }; }"), 0
        )

    def test_malformed_apps_fail(self):
        for i, app in enumerate(
            (
                'type = "app"; program = "${d}/bin/x"; extra = 1;',
                'type = "app"; program = "${d}/bin/x"; meta = 3;',
            )
        ):
            with self.subTest(app=app):
                outputs = "{ apps." + self.system + ".a = { " + app + " }; }"
                self.assertEqual(self.verdict(outputs, f"app{i}"), 1)

    def test_dir_reference_is_evaluated_as_given(self):
        root = self.flake("d", "{ checks." + self.system + ".a = d; }", subdir="sub")
        self.assertEqual(self.eval_outputs(f"path:{root}?dir=sub").returncode, 0)
        self.assertEqual(self.eval_outputs(f"path:{root}").returncode, 1)

    def test_git_identity_reaches_the_evaluation(self):
        git = shutil.which("git")
        if git is None:
            self.skipTest("git not available")
        root = self.flake(
            "g", "{ checks." + self.system + ".a = assert self ? rev; d; }"
        )
        g = [git, "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        for argv in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "t"]):
            subprocess.run([*g, *argv], cwd=root, env=self.env, check=True)
        self.assertEqual(self.eval_outputs(f"git+file://{root}").returncode, 0)
        self.assertEqual(self.eval_outputs(f"path:{root}").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
