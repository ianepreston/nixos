# Server users - Simple Aspect
# Creates the system user matching this host's serverEnvironment with a UID
# aligned to the Synology NAS so OCI containers can read/write NFS-mounted
# volumes without permission translation.
#
# IDs match laconia (Synology):
#   group servers   = 65536
#   user  server-dev  = 1029
#   user  server-prod = 1030
#
# TODO #151: the `uidByEnv` table here and the NFS share tables in
# nfsclient.nix both hard-code the dev/prod environment set.
# Consolidate into one `attrsOf int` table (likely derived onto
# hostSpec as `serverUid`) so adding a third environment (e.g. staging)
# is a one-file change. Not required for the fail-fast assertion layer
# that is the primary goal of issue #151.
{ lib, ... }:
{
  flake.modules.nixos.server-users =
    { hostSpec, ... }:
    let
      uidByEnv = {
        dev = 1029;
        prod = 1030;
      };
    in
    {
      assertions = [
        {
          assertion = hostSpec.serverEnvironment != null;
          message = "server-users requires hostSpec.serverEnvironment to be \"dev\" or \"prod\".";
        }
      ];

      users.groups.servers.gid = 65536;

      users.users = lib.optionalAttrs (hostSpec.serverEnvironment != null) {
        "server-${hostSpec.serverEnvironment}" = {
          uid = uidByEnv.${hostSpec.serverEnvironment};
          isSystemUser = true;
          group = "servers";
          # Hardware-accelerated transcoding (jellyfin and friends)
          # needs read/write access to /dev/dri. Render-only access
          # is the modern split; keep `video` for legacy nodes.
          extraGroups = [
            "render"
            "video"
          ];
        };
      };
    };
}
