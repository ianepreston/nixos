# Replay the authentik blueprint-applied gate against a local fixture API,
# offline (503 with matching JSON, truncated body, proxy env, token quoting).
_: {
  perSystem =
    { pkgs, ... }:
    let
      # Same definition as blueprintReady in modules/apps/authentik.nix, so the
      # test runs the exact wrapper (set -euo pipefail, PATH) the unit runs.
      gate = pkgs.writeShellApplication {
        name = "authentik-blueprint-ready";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
        ];
        text = builtins.readFile ../apps/_authentik/blueprint-ready.sh;
      };
    in
    {
      checks.authentik-blueprint-ready =
        pkgs.runCommand "authentik-blueprint-ready-tests"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              curl
              jq
              python3
            ];
          }
          ''
            cp ${../apps/_authentik/blueprint-ready.sh} blueprint-ready.sh
            cp ${../apps/_authentik/blueprint-ready-test.py} blueprint-ready-test.py
            SCRIPT_BIN=${gate}/bin/authentik-blueprint-ready python3 blueprint-ready-test.py
            touch "$out"
          '';
    };
}
