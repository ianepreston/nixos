# Mocked identity/failure tests for scripts/activate-nixos.sh (#1018). Every
# external command is a logging stub, so no host is contacted or activated.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.activation-identity =
        pkgs.runCommand "activation-identity"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gawk
              gitMinimal
              gnugrep
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
            python3 repo/scripts/activate-nixos-test.py "$PWD/repo"
            touch "$out"
          '';
    };
}
