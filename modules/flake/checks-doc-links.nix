# Fixture tests for scripts/doc-links.py (#1026). The tree check itself runs as
# the `doc-links` pre-commit hook, which sees the whole tracked tree.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.doc-links = pkgs.runCommand "doc-links-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 ${../../scripts/doc-links-test.py} ${../../scripts/doc-links.py}
        touch "$out"
      '';
    };
}
