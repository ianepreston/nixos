# Offline tests for scripts/secrets-publish.sh and scripts/secrets-dir.sh, the
# helpers behind `task secrets:publish` / `task secrets:pin-main` (#1042). The
# nix-secrets origin is a temporary bare repo and `nix` is a stub, so no
# network, real nix-secrets checkout or sops identity is involved.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.secrets-publish =
        pkgs.runCommand "secrets-publish-tests"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gitMinimal
              gnugrep
              go-task
              jq
              python3
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export GIT_CONFIG_NOSYSTEM=1
            export GIT_CONFIG_GLOBAL=/dev/null
            mkdir -p "$HOME" repo/scripts repo/taskfiles
            cp ${../../scripts/secrets-publish.sh} repo/scripts/secrets-publish.sh
            cp ${../../scripts/secrets-dir.sh} repo/scripts/secrets-dir.sh
            cp ${../../scripts/secrets-publish-test.py} repo/scripts/secrets-publish-test.py
            cp ${../../taskfiles/secrets.yaml} repo/taskfiles/secrets.yaml
            chmod -R u+w repo
            python3 repo/scripts/secrets-publish-test.py "$PWD/repo"
            touch "$out"
          '';
    };
}
