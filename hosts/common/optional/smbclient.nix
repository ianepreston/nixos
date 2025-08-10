# create a systemd service to automatically mount the ghost mediashare at boot
{
  inputs,
  config,
  pkgs,
  hostSpec,
  ...
}:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  # required to mount cifs using domain name
  environment.systemPackages = with pkgs; [
    cifs-utils
  ];

  # setup the required secrets
  sops.secrets = {
    "smb-secrets" = {
      sopsFile = "${sopsFolder}/shared.yaml";
      path = "/etc/nixos/smb-secrets";
    };
  };

  fileSystems."/mnt/content" = {
    device = "//laconiatrust/content";
    fsType = "cifs";
    options =
      let
        # separate options to prevent hanging on network split
        # 'noauto'= do not mount via fstab. Will be automounted by systemd
        automount_options = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,user,users";
        # I'm not hard setting these anywhere so I think I can just assume the defaults
        useroptions = "uid=1000,gid=100";
        secoptions = "credentials=/etc/nixos/smb-secrets";
      in
      [ "${automount_options},${useroptions},${secoptions}" ];
  };
  fileSystems."/mnt/laconiahome" = {
    device = "//laconiatrust/home";
    fsType = "cifs";
    options =
      let
        # separate options to prevent hanging on network split
        # 'noauto'= do not mount via fstab. Will be automounted by systemd
        automount_options = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,user,users";
        # I'm not hard setting these anywhere so I think I can just assume the defaults
        useroptions = "uid=1000,gid=100";
        secoptions = "credentials=/etc/nixos/smb-secrets";
      in
      [ "${automount_options},${useroptions},${secoptions}" ];
  };
}
