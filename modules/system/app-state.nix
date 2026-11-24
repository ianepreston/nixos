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
#
# That guard can only see state somebody declared. `myAppStateAudit`
# (below) is the independent check (#1024): on a preservation host it
# reads every enabled unit's systemd `StateDirectory=` and fails eval when
# one is not under a preserved directory, unless the owner declared an
# exemption beside the service. The path rules live in
# _app-state/state-directory-audit.nix.
_: {
  flake.modules.nixos.app-state =
    { config, lib, ... }:
    let
      apps = lib.attrValues config.myAppState;

      stateDirectoryAudit = import ./_app-state/state-directory-audit.nix { inherit lib; };
      audit = stateDirectoryAudit.audit {
        inherit (config.systemd) services;
        inherit (config.myAppStateAudit) exemptions;
        # What preservation actually preserves, gathered the way its own
        # getAllDirectories does (top-level plus per-user directories).
        # `_intermediate` entries only create a parent on both volumes and
        # preserve nothing, so they cover nothing.
        preservedDirs = lib.concatMap (
          root:
          map (d: d.directory) (
            lib.filter (d: d.how != "_intermediate") (
              (root.directories or [ ]) ++ lib.concatMap (u: u.directories) (lib.attrValues (root.users or { }))
            )
          )
        ) (lib.attrValues config.preservation.preserveAt);
      };
      # Every audit failure is one `  <unit>: ...` line, so a message names
      # each offending unit and directory or value exactly.
      lines = f: ds: lib.concatMapStringsSep "\n" (d: "  ${f d}") ds;
      blankReasons = lib.attrNames (
        lib.filterAttrs (_: e: lib.trim e.reason == "") config.myAppStateAudit.exemptions
      );
      owned = owners: lib.concatMapStringsSep ", " (o: "exemptions.${o}") owners;
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

      options.myAppStateAudit.exemptions = lib.mkOption {
        default = { };
        description = ''
          Owner-local exemptions from the `StateDirectory=` coverage audit,
          keyed by owner name and declared beside the service they cover.
          The audit runs on every host with preservation enabled; a unit's
          state directory that no preserved directory covers fails eval
          unless an entry here names that unit and directory.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              unit = lib.mkOption {
                type = lib.types.str;
                example = "homepage-dashboard.service";
                description = "The systemd unit, with its `.service` suffix.";
              };
              directories = lib.mkOption {
                type = lib.types.nonEmptyListOf lib.types.str;
                example = [ "/var/lib/private/homepage-dashboard" ];
                description = ''
                  Normalized absolute state directories of `unit`, as the
                  audit names them: /var/lib/<dir>, or
                  /var/lib/private/<dir> for a DynamicUser unit.
                '';
              };
              disposition = lib.mkOption {
                type = lib.types.enum [
                  "disposable"
                  "pending"
                ];
                description = ''
                  `disposable`: the owner decided the state may be lost on
                  every reboot. `pending`: a known uncovered directory
                  still awaiting the owner's preserve-or-discard decision;
                  it passes eval but emits a warning on every build.
                '';
              };
              reason = lib.mkOption {
                type = lib.types.str;
                description = "Why the state may be lost, or what decision is pending. Must not be empty.";
              };
            };
          }
        );
      };

      config = lib.mkMerge [
        {
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
        }

        {
          # StateDirectory coverage audit (#1024). Validation only: nothing
          # here adds a preservation entry or a restic path.
          assertions = lib.optionals config.preservation.enable [
            {
              assertion = audit.uncovered == [ ];
              message = ''
                myAppStateAudit: these systemd StateDirectory paths are not
                under any preserved directory, so impermanence wipes them on
                every reboot:

                ${lines (d: "${d.unit}: ${d.directory}") audit.uncovered}

                Declare `myAppState.<app>` in the owning module to preserve
                (and by default back up) the state, or, beside the service,
                a `myAppStateAudit.exemptions.<owner>` entry with a reason.
                See docs/agents/app-state.md.
              '';
            }
            {
              assertion = audit.invalid == [ ];
              message = ''
                myAppStateAudit: these unit settings cannot be audited, so
                their state cannot be shown to be preserved; write them in
                the plain form systemd documents:

                ${lines (d: "${d.unit}: ${d.option} value `${d.value}` (${d.why})") audit.invalid}
              '';
            }
            {
              assertion = audit.stale == [ ];
              message = ''
                myAppStateAudit: these exemptions name a unit/directory that
                is not an uncovered StateDirectory on this host (renamed,
                removed, already preserved, or not normalized); drop or fix
                them:

                ${lines (d: "${d.unit}: ${d.directory} (${owned [ d.owner ]})") audit.stale}
              '';
            }
            {
              assertion = audit.conflicts == [ ];
              message = ''
                myAppStateAudit: more than one exemption claims the same
                unit and directory; keep one, beside the service's owner:

                ${lines (d: "${d.unit}: ${d.directory} (${owned d.owners})") audit.conflicts}
              '';
            }
            {
              assertion = blankReasons == [ ];
              message = ''
                myAppStateAudit: these exemptions have an empty `reason`;
                say why the state may be lost or what decision is pending:

                ${lines (o: owned [ o ]) blankReasons}
              '';
            }
          ];

          warnings = lib.optionals config.preservation.enable (
            map (
              d:
              "myAppStateAudit: ${d.unit} state ${d.directory} is not preserved and awaits an owner decision (${owned [ d.owner ]}): ${d.exemption.reason}"
            ) (lib.filter (d: d.exemption.disposition == "pending") audit.exempted)
          );
        }
      ];
    };
}
