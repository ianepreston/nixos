# Offline tests for scripts/flake-checks.sh (#1021), the driver behind
# `task check` and the CI check stages. `nix` is a stub answering from a
# synthetic flake, so nothing is evaluated, built, fetched or delegated to a
# builder; the tests cover discovery, failure propagation, platform refusal and
# DEFERRED reporting, and run `task check`/`task check:linux` against the stub.
_: {
  perSystem =
    { pkgs, ... }:
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
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" repo/scripts
            cp ${../../scripts/flake-checks.sh} repo/scripts/flake-checks.sh
            cp ${../../scripts/flake-checks-test.py} repo/scripts/flake-checks-test.py
            cp ${../../Taskfile.yaml} repo/Taskfile.yaml
            chmod -R u+w repo
            python3 repo/scripts/flake-checks-test.py "$PWD/repo"
            touch "$out"
          '';
    };
}
