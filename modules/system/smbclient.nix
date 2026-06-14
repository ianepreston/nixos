# SMB Client - Simple Aspect
# CIFS mounts for laconiatrust shares
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.smbclient =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        cifs-utils
      ];

      # CIFS stores files on the NAS owned by the *authenticated SMB user*,
      # not the local `uid=` mount option (Synology doesn't run CIFS Unix
      # extensions, so `uid=`/`gid=` only affect local presentation). Mount
      # each share as the DSM identity whose ownership the servers expect:
      # content as server-prod and dev-content as server-dev (UIDs 1030/1029,
      # matching the NFS owners the prod/dev servers read and write as), so
      # files copied from a workstation land owned correctly instead of as
      # the personal account. Home stays the personal account.
      sops.secrets = {
        "smb-secrets" = {
          sopsFile = "${sopsFolder}/shared.yaml";
          path = "/etc/nixos/smb-secrets";
        };
        "smb-secrets-prod" = {
          sopsFile = "${sopsFolder}/shared.yaml";
          path = "/etc/nixos/smb-secrets-prod";
        };
        "smb-secrets-dev" = {
          sopsFile = "${sopsFolder}/shared.yaml";
          path = "/etc/nixos/smb-secrets-dev";
        };
      };

      fileSystems =
        let
          automount_options = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,user,users";
          useroptions = "uid=1000,gid=100";
          mkShare = device: credsFile: {
            inherit device;
            fsType = "cifs";
            options = [ "${automount_options},${useroptions},credentials=${credsFile}" ];
          };
        in
        {
          "/mnt/content" = mkShare "//laconia/content" "/etc/nixos/smb-secrets-prod";
          "/mnt/dev_content" = mkShare "//laconia/dev-content" "/etc/nixos/smb-secrets-dev";
          "/mnt/laconiahome" = mkShare "//laconia/home" "/etc/nixos/smb-secrets";
        };
    };
}
