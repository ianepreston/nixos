# Queue/ownership invariants and the denied-action finisher (finish_child.py)
# use disposable Git repos and a stub gh, never agents, GitHub or live hosts.
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
            python3 scripts/finish_child_test.py
            touch "$out"
          '';
    };
}
