# Run the production recovery templates with inert restore commands. The VM
# additionally checks real systemd refusal to stop a still-running service.
_: {
  perSystem =
    { pkgs, lib, ... }:
    let
      testPython = ../../scripts/recovery-stop-test.py;
      taskfile = ../../taskfiles/recovery.yaml;
      packages = with pkgs; [
        bash
        coreutils
        gawk
        go-task
        python3
      ];
    in
    {
      checks = {
        recovery-stop = pkgs.runCommand "recovery-stop" { nativeBuildInputs = packages; } ''
          python3 ${testPython} ${taskfile}
          touch "$out"
        '';
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        recovery-stop-systemd = pkgs.testers.runNixOSTest {
          name = "recovery-stop-systemd";
          nodes.machine = {
            environment.systemPackages = packages;
            systemd.services = lib.genAttrs [ "recovery-writer" "recovery-other" "recovery-blocked" ] (name: {
              unitConfig.RefuseManualStop = name == "recovery-blocked";
              serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            });
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.succeed("python3 ${testPython} ${taskfile} --systemd /run/current-system/sw/bin/systemctl")
          '';
        };
      };
    };
}
