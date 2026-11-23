# Fixture tests for scripts/reconcile-ha-component-requirements.sh (#1065), the
# reconciler Renovate runs on Home Assistant custom-component pins. The test
# redirects manifest and PyPI-hash lookups to fixtures, so no network request
# is made. It locates the repo with `git rev-parse --show-toplevel`, so the
# scripts are copied into a throwaway git repository.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.ha-reconcile =
        pkgs.runCommand "ha-reconcile-tests"
          {
            # Every tool the reconciler's fail-fast PATH check lists (nix and
            # nix-prefetch-url come from pkgs.nix; the fixture path never runs
            # them).
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              curl
              diffutils
              gawk
              gitMinimal
              gnugrep
              gnused
              jq
              nix
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export GIT_CONFIG_NOSYSTEM=1
            export GIT_CONFIG_GLOBAL=/dev/null
            mkdir -p "$HOME" repo
            cp -r ${../../scripts} repo/scripts
            chmod -R u+w repo
            # The sandbox has no /usr/bin/env, which the scripts' shebangs use.
            patchShebangs repo/scripts
            git -C repo init --quiet
            (cd repo && bash scripts/test-reconcile-ha-component-requirements.sh) | tee test.log
            grep -Fx 'test-reconcile-ha-component-requirements: ok' test.log
            touch "$out"
          '';
    };
}
