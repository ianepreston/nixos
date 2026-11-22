# Assertion-logic tests for scripts/sops-recipient-matrix.py, the script behind
# `task secrets:matrix` (#1020). Recipients, anchors and consumers are literals
# in the test, so no nix-secrets checkout, sops envelope, yq, ssh-keyscan or
# host is involved.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.sops-recipient-matrix =
        pkgs.runCommand "sops-recipient-matrix-tests"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            cp ${../../scripts/sops-recipient-matrix.py} sops-recipient-matrix.py
            cp ${../../scripts/sops-recipient-matrix-test.py} sops-recipient-matrix-test.py
            python3 sops-recipient-matrix-test.py
            touch "$out"
          '';
    };
}
