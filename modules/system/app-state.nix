# App state - single source of truth for a native server-app's on-disk
# state directory.
#
# Before this module, every native server-app with persistent state
# declared the SAME path in three-to-four hand-synced places:
#   1. `preservation.preserveAt."/persist".directories` (so the state
#      survives a reboot under impermanence),
#   2. `services.restic.backups.server.paths` (so it lands in the
#      nightly snapshot),
#   3. `expectedPreservedDirs` in BOTH modules/profiles/dev-server-apps.nix
#      and modules/profiles/prod-server-apps.nix (the structural guard).
#
# #136 was exactly this class of bug: native arrs / readeck shipped on
# hpp-1 with impermanence enabled but no preservation entry, and only
# the lack of a reboot between deploy and audit kept it from silently
# wiping state. The `expectedPreservedDirs` guard made that structural,
# but it was itself a fourth edit and could not catch a missing restic
# path or a stale entry left behind after removal.
#
# `myAppState.<app>` collapses all of that into one declaration. From a
# single entry this module derives the preservation entry and the
# restic path; the two server-apps profiles derive their
# `expectedPreservedDirs` guard from `config.myAppState` (see the
# comment there). Adding a native app now means one `myAppState.<app>`
# block in the app module and no profile edit.
_: {
  flake.modules.nixos.app-state =
    { config, lib, ... }:
    let
      apps = lib.attrValues config.myAppState;
    in
    {
      options.myAppState = lib.mkOption {
        default = { };
        description = ''
          Native server-app on-disk state. Keyed by app name; each entry
          is the single source of truth for that app's persisted state
          directory, deriving the impermanence preservation entry and
          the restic backup path.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              stateDir = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The app's persisted state directory (e.g.
                  "/var/lib/radarr"). For DynamicUser services whose
                  real storage lives under /var/lib/private/<app>, use
                  that private path — it is what actually needs
                  preserving and backing up.
                '';
              };
              user = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Owner of the preserved directory. Null omits the field
                  from the preservation entry, letting preservation's
                  default (root) apply — matches DynamicUser services
                  that manage ownership themselves.
                '';
              };
              group = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "servers";
                description = ''
                  Group of the preserved directory. Defaults to the
                  shared `servers` group used by NFS-aligned apps; set to
                  the app's own group for apps that run as a per-package
                  user, or null to omit (DynamicUser).
                '';
              };
              mode = lib.mkOption {
                type = lib.types.str;
                default = "0700";
                description = "Mode of the preserved directory.";
              };
              backupPath = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Path to back up with restic. Null (the default) backs
                  up `stateDir`; override only when the backup source
                  differs from the preserved directory.
                '';
              };
            };
          }
        );
      };

      config = {
        # Preservation entry per app. user/group are omitted when null so
        # the effective attrs match a hand-written entry that leaves them
        # to preservation's defaults (DynamicUser apps).
        preservation.preserveAt."/persist".directories = map (
          a:
          {
            directory = a.stateDir;
            inherit (a) mode;
          }
          // lib.optionalAttrs (a.user != null) { inherit (a) user; }
          // lib.optionalAttrs (a.group != null) { inherit (a) group; }
        ) apps;

        # Restic path per app: the explicit backupPath, else the stateDir.
        services.restic.backups.server.paths = map (
          a: if a.backupPath != null then a.backupPath else a.stateDir
        ) apps;
      };
    };
}
