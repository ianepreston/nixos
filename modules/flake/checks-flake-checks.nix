# Offline tests for scripts/flake-checks.sh (#1021), the driver behind
# `task check` and the CI check stages:
#   - scripts/flake-checks-test.py runs the driver against a stub `nix` that
#     answers from a synthetic flake, so nothing is evaluated, built, fetched or
#     delegated; it covers discovery, name handling, exit-status propagation,
#     platform/builder gating and DEFERRED reporting, and runs
#     `task check`/`task check:linux` against the stub;
#   - scripts/_flake-checks/tests.nix runs the real Nix checks the driver
#     applies (derivations.nix, toplevel.nix) on synthetic values under
#     tryEval, at evaluation time; the build compares them with the expected
#     accept/reject table.
_: {
  perSystem =
    { pkgs, ... }:
    let
      expressionCases = import ../../scripts/_flake-checks/tests.nix {
        inherit (pkgs.stdenv.hostPlatform) system;
      };
    in
    {
      checks.flake-checks =
        pkgs.runCommand "flake-checks-tests"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gnugrep
              gnused
              go-task
              jq
              python3
            ];
            actual = builtins.toJSON expressionCases.actual;
            expected = builtins.toJSON expressionCases.expected;
          }
          ''
            echo "$actual" | jq -S . > actual.json
            echo "$expected" | jq -S . > expected.json
            if ! diff -u expected.json actual.json; then
              echo "flake-checks: Nix expression cases differ from the expected table" >&2
              exit 1
            fi
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" repo/scripts
            cp -r ${../../scripts/_flake-checks} repo/scripts/_flake-checks
            cp ${../../scripts/flake-checks.sh} repo/scripts/flake-checks.sh
            cp ${../../scripts/flake-checks-test.py} repo/scripts/flake-checks-test.py
            cp ${../../Taskfile.yaml} repo/Taskfile.yaml
            chmod -R u+w repo
            python3 repo/scripts/flake-checks-test.py "$PWD/repo"
            touch "$out"
          '';
    };
}
