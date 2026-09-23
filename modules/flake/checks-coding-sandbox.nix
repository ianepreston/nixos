# Static policy tests for the macOS-only Lima launcher.  They run on every
# supported evaluation platform because TOML parsing and policy rendering are
# host-side, with no Lima VM required.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.coding-sandbox-policy =
        pkgs.runCommand "coding-sandbox-policy"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.bash
              pkgs.coreutils
              pkgs.gawk
              pkgs.gnused
              pkgs.jq
              pkgs.python3
            ];
          }
          ''
            ${pkgs.python3}/bin/python ${../programs/coding-sandbox-policy-test.py} \
              ${../programs/coding-sandbox-policy.py} \
              ${../programs/coding-sandbox.sh}
            touch "$out"
          '';
    };
}
