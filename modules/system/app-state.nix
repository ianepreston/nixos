# App state - single source of truth for server-owned on-disk state
# and its backup policy.
#
# Before this module, every native server-app with persistent state
# declared the SAME path in three-to-four hand-synced places:
#   1. `preservation.preserveAt."/persist".directories` (so the state
#      survives a reboot under impermanence),
#   2. `services.restic.backups.server.paths` (so it lands in the
#      nightly snapshot),
#   3. `expectedPreservedDirs` in modules/profiles/server-apps.nix (the
#      structural guard).
#
# #136 was exactly this class of bug: the native arrs shipped on
# hpp-1 with impermanence enabled but no preservation entry, and only
# the lack of a reboot between deploy and audit kept it from silently
# wiping state. The `expectedPreservedDirs` guard made that structural,
# but it was itself a fourth edit and could not catch a missing restic
# path or a stale entry left behind after removal.
#
# `myAppState.<app>` collapses all of that into one declaration. From a
# single entry this module derives the preservation entry and, unless
# explicitly opted out, the restic path; the two server-apps profiles
# derive their `expectedPreservedDirs` guard from `config.myAppState` (see the
# comment there). Adding owned state now means one `myAppState.<name>`
# block in its module and no profile edit.
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
          Server-owned on-disk state. Keyed by owner name; each entry is
          the single source of truth for that owner's persisted state
          directory, deriving the impermanence preservation entry and,
          by default, the restic backup path.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { config, ... }:
            {
              options = {
                dynamicUser = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    The owning service uses systemd `DynamicUser=` with a
                    `StateDirectory=` under /var/lib/private. systemd keeps
                    such a directory on disk as nobody:nogroup, with the
                    unit's `StateDirectoryMode=` (default 0755), and id-maps
                    it to the service's transient UID at start, so the
                    preservation entry must assert that same owner and
                    mode. Leaving the preservation default (root) in place
                    means every `systemd-tmpfiles-resetup` run on a switch
                    hands the top-level directory back to root under the
                    running service, which then cannot write to it (or,
                    at 0700, even traverse it) until restarted (#949).

                    Setting this changes the `user`/`group` defaults to
                    nobody/nogroup (overriding either is an eval error)
                    and the `mode` default to 0755. Set `mode` to match
                    the unit's `StateDirectoryMode=` when upstream
                    changes it, or the two fight over the mode instead.
                  '';
                };
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
                  default = if config.dynamicUser then "nobody" else null;
                  defaultText = lib.literalExpression ''if dynamicUser then "nobody" else null'';
                  description = ''
                    Owner of the preserved directory. Null omits the field
                    from the preservation entry, so preservation's default
                    (root) applies. Not suitable for DynamicUser services:
                    preservation renders that default into a tmpfiles `d`
                    rule, which re-asserts it on an existing directory. Use
                    `dynamicUser` for those.
                  '';
                };
                group = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = if config.dynamicUser then "nogroup" else "servers";
                  defaultText = lib.literalExpression ''if dynamicUser then "nogroup" else "servers"'';
                  description = ''
                    Group of the preserved directory. Defaults to the
                    shared `servers` group used by NFS-aligned apps; set to
                    the app's own group for apps that run as a per-package
                    user, or null to omit (root).
                  '';
                };
                mode = lib.mkOption {
                  type = lib.types.str;
                  default = if config.dynamicUser then "0755" else "0700";
                  defaultText = lib.literalExpression ''if dynamicUser then "0755" else "0700"'';
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
                backup = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = ''
                    Whether to include this state in the server's restic
                    backup. Set false for data that must survive a reboot but
                    is intentionally not restorable, such as incomplete
                    downloads, derived metrics, or re-downloadable caches.
                  '';
                };
              };
            }
          )
        );
      };

      config = {
        # A DynamicUser entry must render the owner systemd leaves on disk,
        # or tmpfiles and systemd fight over the top-level directory (see
        # the `dynamicUser` description).
        assertions =
          lib.mapAttrsToList (name: a: {
            assertion = !a.dynamicUser || (a.user == "nobody" && a.group == "nogroup");
            message = ''
              myAppState.${name}: dynamicUser = true requires user/group to
              stay at nobody/nogroup (got ${toString a.user}/${toString a.group}).
            '';
          }) config.myAppState
          # Catch the same mistake from any preservation entry, not only
          # myAppState ones: everything under /var/lib/private is a
          # DynamicUser StateDirectory, and preservation's root default
          # re-creates #949 for it.
          ++
            map
              (d: {
                assertion = d.user == "nobody" && d.group == "nogroup";
                message = ''
                  preservation entry ${d.directory} is a DynamicUser state
                  directory but renders ${d.user}:${d.group}; declare it via
                  `myAppState.<app>.dynamicUser = true` (#949).
                '';
              })
              (
                lib.filter (d: lib.hasPrefix "/var/lib/private/" d.directory) (
                  config.preservation.preserveAt."/persist".directories or [ ]
                )
              );

        # Preservation entry per app. user/group are omitted when null so
        # the effective attrs match a hand-written entry that leaves them
        # to preservation's defaults (root).
        preservation.preserveAt."/persist".directories = map (
          a:
          {
            directory = a.stateDir;
            inherit (a) mode;
          }
          // lib.optionalAttrs (a.user != null) { inherit (a) user; }
          // lib.optionalAttrs (a.group != null) { inherit (a) group; }
        ) apps;

        # Restic path per app that participates in backup: the explicit
        # backupPath, else the stateDir. Preservation always follows
        # stateDir, even for preserve-only entries.
        services.restic.backups.server.paths = map (
          a: if a.backupPath != null then a.backupPath else a.stateDir
        ) (lib.filter (a: a.backup) apps);
      };
    };
}
