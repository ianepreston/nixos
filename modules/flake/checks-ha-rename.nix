# Offline websocket-stub and file-fixture tests for scripts/ha-rename.py.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.ha-rename = pkgs.runCommand "ha-rename-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        cp ${../../scripts/ha-rename.py} ha-rename.py
        cp ${../../scripts/ha-rename-test.py} ha-rename-test.py
        python3 ha-rename-test.py
        touch "$out"
      '';
    };
}
