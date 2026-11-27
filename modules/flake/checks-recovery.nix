# Offline recovery checks (#1017, #1025). The restore driver
# (scripts/recovery.sh), its target side (scripts/_recovery/remote.sh) and the
# Task entry points run with inert, recording stand-ins for ssh, systemctl,
# restic, postgres and the rest; nothing connects to a host or restores app
# data. The VM additionally checks real systemd refusal to stop a
# still-running service, and a model of a container's init (#1122).
{ inputs, ... }:
{
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
      # Model of podman-bookorbit's stop path (#1122), built from the
      # drill VM's published `myContainerApp.bookorbit` contribution so it
      # follows the app module. The image's root `tini -s --` forwards
      # SIGTERM to the app, which runs as another uid, with only
      # `capabilities` (podman adds them after `--cap-drop=ALL`). Here tini
      # is the unit's main process (podman's conmon and catatonit only pass
      # its status through), setpriv stands in for su-exec, and
      # KillMode=mixed matches `podman stop` signalling only PID 1.
      bookorbit = inputs.self.nixosConfigurations.tests-server.config.myContainerApp.bookorbit;
      # Null would mean podman's default caps, which this bounding set
      # would no longer model.
      bookorbitCaps =
        assert bookorbit.capabilities != null;
        map (c: "CAP_${c}") bookorbit.capabilities;
      containerInit =
        {
          caps,
          successExitStatus,
          app ? "${pkgs.coreutils}/bin/sleep infinity",
        }:
        {
          serviceConfig = {
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.tini}/bin/tini -s --"
              "${pkgs.util-linux}/bin/setpriv --reuid=nobody --regid=nogroup --clear-groups"
              app
            ];
            CapabilityBoundingSet = caps;
            NoNewPrivileges = true;
            KillMode = "mixed";
            SuccessExitStatus = successExitStatus;
            # Stands in for podman's stop timeout (SIGKILL, exit 137).
            TimeoutStopSec = 2;
          };
        };
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
            systemd.services =
              lib.genAttrs [ "recovery-writer" "recovery-other" "recovery-blocked" ] (name: {
                unitConfig.RefuseManualStop = name == "recovery-blocked";
                serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              })
              // {
                # bookorbit as configured: stops cleanly.
                recovery-init-app = containerInit {
                  caps = bookorbitCaps;
                  successExitStatus = bookorbit.cleanStopExitStatus;
                };
                # bookorbit before #1122: stop returns 0, unit ends failed.
                recovery-init-nokill = containerInit {
                  caps = lib.remove "CAP_KILL" bookorbitCaps;
                  successExitStatus = [ ];
                };
                # bookorbit as configured, but the app ignores SIGTERM: the
                # clean-stop status must not hide a stop that times out.
                recovery-init-hung = containerInit {
                  caps = bookorbitCaps;
                  successExitStatus = bookorbit.cleanStopExitStatus;
                  app = "${pkgs.bash}/bin/bash -c \"trap '' TERM; exec ${pkgs.coreutils}/bin/sleep infinity\"";
                };
              };
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.succeed("python3 ${src}/scripts/recovery-stop-test.py ${src}/taskfiles/recovery.yaml --systemd /run/current-system/sw/bin/systemctl")
          '';
        };
      };
    };
}
