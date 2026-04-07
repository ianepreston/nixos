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

      sops.secrets = {
        "smb-secrets" = {
          sopsFile = "${sopsFolder}/shared.yaml";
          path = "/etc/nixos/smb-secrets";
        };
      };

      fileSystems =
        let
          automount_options = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,user,users";
          useroptions = "uid=1000,gid=100";
          secoptions = "credentials=/etc/nixos/smb-secrets";
        in
        {
          "/mnt/content" = {
            device = "//laconia/content";
            fsType = "cifs";
            options = [ "${automount_options},${useroptions},${secoptions}" ];
          };
          "/mnt/laconiahome" = {
            device = "//laconia/home";
            fsType = "cifs";
            options = [ "${automount_options},${useroptions},${secoptions}" ];
          };
        };
    };
}
