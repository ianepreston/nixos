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
# ──────────────────────────────────────────────────────────────────────────
# UID registry
# ──────────────────────────────────────────────────────────────────────────
# Central record of every statically-pinned UID in this flake. Allocate
# the next free number from the appropriate range when adding a new app
# that needs a stable UID (e.g. a `services.<app>` module whose nixpkgs
# default is DynamicUser=true but where we want a fixed UID for NFS or
# persistent-volume ownership). The collision assertion below will fail
# evaluation if two `users.users.*.uid` values ever clash.
#
#   890-899   server apps with bypassed DynamicUser (native services that
#             need a fixed UID for NFS share access or persistent state)
#     891    prowlarr          (modules/apps/prowlarr.nix)
#     892    mealie            (modules/apps/mealie.nix)
#     893    readeck           (modules/apps/readeck.nix)
#
#   1029-1030 Shared server-{dev,prod} NFS user (UID matches Synology NAS)
#     1029   server-dev
#     1030   server-prod
#
# Apps that consume the shared server-{dev,prod} UID (containers, sabnzbd's
# DynamicUser override, etc.) read it from `hostSpec.serverUid` — they do
# not need their own entry above.
#
# The username/uid/group/gid are now derived on hostSpec
# (serverUser/serverUid/serverGroup/serverGid, see hostSpecs/_host-spec.nix)
# and this module is their sole materialiser — the former inline `uidByEnv`
# table lived here. Remaining half of #151: the NFS share tables in
# nfsclient.nix still hard-code the dev/prod environment set; folding those
# onto hostSpec too would make adding a third environment a one-file change.
# ──────────────────────────────────────────────────────────────────────────
{ lib, ... }:
{
  flake.modules.nixos.server-users =
    {
      config,
      hostSpec,
      ...
    }:
    let
      # Detect colliding statically-pinned UIDs across the whole
      # nixosConfiguration. Builds { "<uid>" = [ "<userA>" "<userB>" … ]; }
      # then filters to entries with more than one holder.
      pinnedUsers = lib.filterAttrs (_: u: u.uid != null) config.users.users;
      uidToNames = lib.foldlAttrs (
        acc: name: user:
        acc
        // {
          ${toString user.uid} = (acc.${toString user.uid} or [ ]) ++ [ name ];
        }
      ) { } pinnedUsers;
      collisions = lib.filterAttrs (_: names: lib.length names > 1) uidToNames;
    in
    {
      assertions = [
        {
          assertion = hostSpec.serverEnvironment != null;
          message = "server-users requires hostSpec.serverEnvironment to be \"dev\" or \"prod\".";
        }
        {
          assertion = collisions == { };
          message =
            "UID collision detected — two or more users.users.*.uid values share the same UID. "
            + "See the UID registry block at the top of modules/system/server-users.nix and pick a free number. "
            + "Conflicts: "
            + lib.concatStringsSep "; " (
              lib.mapAttrsToList (uid: names: "uid ${uid} → ${lib.concatStringsSep ", " names}") collisions
            );
        }
      ];

      users.groups.${hostSpec.serverGroup}.gid = hostSpec.serverGid;

      users.users = lib.optionalAttrs (hostSpec.serverUser != null) {
        ${hostSpec.serverUser} = {
          uid = hostSpec.serverUid;
          isSystemUser = true;
          group = hostSpec.serverGroup;
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
