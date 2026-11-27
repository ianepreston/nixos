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
      # drill VM's real rendered config so it follows the app module. The
      # image's root `tini -s --` forwards SIGTERM to the app, which runs as
      # another uid; `--cap-drop=ALL` leaves only the `--cap-add`s. Here
      # tini is the unit's main process (podman's conmon and catatonit only
      # pass its status through), setpriv stands in for su-exec, and
      # KillMode=mixed matches `podman stop` signalling only PID 1.
      drill = inputs.self.nixosConfigurations.tests-server.config;
      bookorbitOptions = drill.virtualisation.oci-containers.containers.bookorbit.extraOptions;
      # Without --cap-drop=ALL the container keeps podman's default caps and
      # this bounding set would no longer model it.
      bookorbitCaps =
        assert lib.elem "--cap-drop=ALL" bookorbitOptions;
        map (o: "CAP_${lib.removePrefix "--cap-add=" o}") (
          lib.filter (lib.hasPrefix "--cap-add=") bookorbitOptions
        );
      containerInit =
        { caps, successExitStatus }:
        {
          serviceConfig = {
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.tini}/bin/tini -s --"
              "${pkgs.util-linux}/bin/setpriv --reuid=nobody --regid=nogroup --clear-groups"
              "${pkgs.coreutils}/bin/sleep infinity"
            ];
            CapabilityBoundingSet = caps;
            NoNewPrivileges = true;
            KillMode = "mixed";
            SuccessExitStatus = successExitStatus;
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
                  successExitStatus = drill.systemd.services.podman-bookorbit.serviceConfig.SuccessExitStatus or [ ];
                };
                # bookorbit before #1122: stop returns 0, unit ends failed.
                recovery-init-nokill = containerInit {
                  caps = lib.remove "CAP_KILL" bookorbitCaps;
                  successExitStatus = [ ];
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
