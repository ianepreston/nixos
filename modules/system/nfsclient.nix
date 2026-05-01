# NFS Client - Simple Aspect
# NFS mounts for laconia (Synology). Each server gets its own
# environment's content/backups at predictable paths (/mnt/content,
# /mnt/backups) and the other environment exposed read-only at
# /mnt/<otherEnv>-content / /mnt/<otherEnv>-backups for migrations or
# copies. UID/GID-based access control on the NAS (server-dev 1029,
# server-prod 1030, group servers 65536) decides who can actually write.
_: {
  flake.modules.nixos.nfsclient =
    { hostSpec, ... }:
    let
      nasHost = "laconia.ipreston.net";

      contentByEnv = {
        dev = "dev-content";
        prod = "content";
      };
      backupsByEnv = {
        dev = "server-dev-backups";
        prod = "server-prod-backups";
      };

      env = hostSpec.serverEnvironment;
      otherEnv = if env == "dev" then "prod" else "dev";

      automountOpts = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=600"
        "x-systemd.device-timeout=10s"
        "x-systemd.mount-timeout=10s"
      ];

      mkMount = share: {
        device = "${nasHost}:/volume1/${share}";
        fsType = "nfs";
        options = automountOpts;
      };
    in
    {
      assertions = [
        {
          assertion = env != null;
          message = "nfsclient requires hostSpec.serverEnvironment to be \"dev\" or \"prod\".";
        }
      ];

      boot.supportedFilesystems = [ "nfs" ];

      fileSystems = {
        "/mnt/content" = mkMount contentByEnv.${env};
        "/mnt/backups" = mkMount backupsByEnv.${env};
        "/mnt/${otherEnv}-content" = mkMount contentByEnv.${otherEnv};
        "/mnt/${otherEnv}-backups" = mkMount backupsByEnv.${otherEnv};
      };
    };
}
