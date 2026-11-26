# Offline tests for scripts/flake-checks.sh (#1021), the driver behind
# `task check` and the CI check stages (scripts/flake-checks-test.py):
#   - stub tests: `nix` is a stub answering from a synthetic flake, so nothing
#     is evaluated, built, fetched or delegated; they cover discovery, the name
#     choke point, exit-status and decode-failure propagation, the builders
#     gate, DEFERRED reporting and flake-reference identity, and run
#     `task check`/`task check:linux` against the stub;
#   - real-nix tests: the driver's eval-outputs stage runs this nixpkgs' real
#     `nix flake check --no-build` on small synthetic flakes in a private
#     store under $TMPDIR (no daemon, no network, nothing outside the build),
#     showing the gate keeps nix's own verdicts and the given flake identity.
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
              gitMinimal
              gnugrep
              gnused
              go-task
              jq
              python3
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export FLAKE_CHECKS_REAL_NIX=${pkgs.nix}/bin
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
