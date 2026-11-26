# Offline recovery checks (#1017, #1025). The restore driver
# (scripts/recovery.sh), its target side (scripts/_recovery/remote.sh) and the
# Task entry points run with inert, recording stand-ins for ssh, systemctl,
# restic, postgres and the rest; nothing connects to a host or restores app
# data. The VM additionally checks real systemd refusal to stop a
# still-running service.
_: {
  perSystem =
    { pkgs, lib, ... }:
    let
      # The Task wrappers find the driver relative to their own file.
      src = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ../../taskfiles/recovery.yaml
          ../../scripts/recovery.sh
          ../../scripts/_recovery
          ../../scripts/recovery-test.py
          ../../scripts/recovery-stop-test.py
        ];
      };
      # The Linux build sandbox has no /usr/bin/env for the scripts' shebang.
      copySrc = ''
        cp -r ${src} repo
        chmod -R u+w repo
        patchShebangs repo/scripts
      '';
      packages = with pkgs; [
        bash
        coreutils
        gawk
        gnused
        go-task
        jq
        python3
      ];
    in
    {
      checks = {
        recovery-stop = pkgs.runCommand "recovery-stop" { nativeBuildInputs = packages; } ''
          ${copySrc}
          python3 repo/scripts/recovery-stop-test.py repo/taskfiles/recovery.yaml
          touch "$out"
        '';
        recovery-dispatch = pkgs.runCommand "recovery-dispatch" { nativeBuildInputs = packages; } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          ${copySrc}
          python3 repo/scripts/recovery-test.py repo
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
            machine.succeed("python3 ${src}/scripts/recovery-stop-test.py ${src}/taskfiles/recovery.yaml --systemd /run/current-system/sw/bin/systemctl")
          '';
        };
      };
    };
}
