# Replay the authentik blueprint-applied gate against a local fixture API,
# offline (503 with matching JSON, truncated body, proxy env, token quoting).
_: {
  perSystem =
    { pkgs, ... }:
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
            python3 blueprint-ready-test.py
            touch "$out"
          '';
    };
}
