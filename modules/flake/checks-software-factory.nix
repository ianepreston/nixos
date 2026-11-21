# Queue/ownership invariants use disposable Git repos, never agents or live hosts.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.software-factory =
        pkgs.runCommand "software-factory-tests"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.gitMinimal
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export GIT_CONFIG_NOSYSTEM=1
            export GIT_CONFIG_GLOBAL=/dev/null
            mkdir -p "$HOME"
            cp -r ${../../skills/software-factory/scripts} scripts
            python3 scripts/factory_test.py
            touch "$out"
          '';
    };
}
