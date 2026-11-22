# Offline tests for scripts/validate-host.py (#1063): the activation helper,
# nix, ssh and the target's commands are logging stubs, so no host is
# contacted or activated.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.validate-host =
        pkgs.runCommand "validate-host"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gitMinimal
              go-task
              python3
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export GIT_CONFIG_NOSYSTEM=1
            export GIT_CONFIG_GLOBAL=/dev/null
            mkdir -p "$HOME" repo/taskfiles
            cp -r ${../../scripts} repo/scripts
            cp ${../../Taskfile.yaml} repo/Taskfile.yaml
            cp ${../../taskfiles}/*.yaml repo/taskfiles/
            chmod -R u+w repo
            python3 repo/scripts/validate-host-test.py "$PWD/repo"
            touch "$out"
          '';
    };
}
